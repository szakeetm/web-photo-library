import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import PhotoCore

/// Exports in progress: a ZIP streamed to the browser, or files written into a folder on this Mac.
final class ExportRegistry: @unchecked Sendable {
    struct Job {
        let id: String
        let name: String
        let options: ExportOptions
        let entries: [ExportEntry]
        var state = "ready"          // ready | running | done | failed | cancelled
        var done = 0
        var error: String?
        var folder: String?
        var cancelled = false
        let created = Date()
    }

    struct Status: Encodable {
        let id: String
        let name: String
        let state: String
        let done: Int
        let total: Int
        let error: String?
        let folder: String?
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]

    func add(_ job: Job) {
        lock.lock(); defer { lock.unlock() }
        // forget finished exports after an hour
        jobs = jobs.filter { $0.value.state == "running" || Date().timeIntervalSince($0.value.created) < 3600 }
        jobs[job.id] = job
    }

    func get(_ id: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[id] }

    func update(_ id: String, _ change: (inout Job) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if var j = jobs[id] { change(&j); jobs[id] = j }
    }

    /// Marks a ready export running; false when it already ran (a ZIP can be downloaded once).
    func start(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var j = jobs[id], j.state == "ready" else { return false }
        j.state = "running"
        jobs[id] = j
        return true
    }

    func isCancelled(_ id: String) -> Bool { get(id)?.cancelled ?? true }

    func status(_ id: String) -> Status? {
        get(id).map { Status(id: $0.id, name: $0.name, state: $0.state, done: $0.done, total: $0.entries.count, error: $0.error, folder: $0.folder) }
    }
}

extension APIRoutes {
    struct ExportRequest: Decodable {
        let options: ExportOptions
        /// "zip" (download) or "folder" (on this Mac, local mode only)
        let target: String
        let folder: String?
        let name: String?
    }

    func registerExportRoutes(on api: RouterGroup<BasicRequestContext>) {
        let registry = ExportRegistry()
        let services = self.services
        @Sendable func exporter() -> ExportService {
            ExportService(db: services.db, catalog: services.catalog, edits: services.edits, ffmpeg: services.ffmpeg,
                          cacheDir: services.paths.cacheDir)
        }

        api.post("exports") { req, ctx in
            guard let body = try? await req.decode(as: ExportRequest.self, context: ctx), body.target == "zip" || body.target == "folder" else {
                return errorResponse(.badRequest, "Invalid export.")
            }
            var folder: URL?
            if body.target == "folder" {
                guard LocalClient.isLocal(req) else { return errorResponse(.forbidden, "Exporting to a folder works only on the Mac itself.") }
                guard let path = body.folder, path.hasPrefix("/") else { return errorResponse(.badRequest, "Choose a folder.") }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                    return errorResponse(.badRequest, "That folder doesn't exist.")
                }
                // never into the library (it's read-only to the app) or the app's own data
                let forbidden = [try services.settings.get(.libraryPath), services.paths.dataDir.path].compactMap { $0 }
                if forbidden.contains(where: { PathOverlap.overlaps($0, url.path) }) {
                    return errorResponse(.badRequest, "Choose a folder outside the library and the app's data.")
                }
                folder = url
            }
            let entries: [ExportEntry]
            do { entries = try await blocking { try exporter().plan(body.options) } } catch let e as ExportError {
                return errorResponse(.badRequest, e.description)
            }
            let id = UUID().uuidString.lowercased()
            let stamp = ExportName.stamp(Date())
            let name = ExportName.clean(body.name ?? "") ?? "Photos \(stamp)"
            registry.add(.init(id: id, name: name, options: body.options, entries: entries, folder: folder?.path))

            if let folder {
                // write in the background; the app polls GET /exports/:id
                guard registry.start(id) else { throw HTTPError(.conflict) }
                let target = folder.appendingPathComponent(name, isDirectory: true)
                registry.update(id) { $0.folder = target.path }
                let service = exporter()
                Task.detached {
                    do {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                        try await service.run(entries, format: body.options.format, write: ExportService.writeToFolder(target),
                                              progress: { n in registry.update(id) { $0.done = n } },
                                              isCancelled: { registry.isCancelled(id) })
                        registry.update(id) { $0.state = "done" }
                    } catch {
                        let cancelled = registry.isCancelled(id)
                        registry.update(id) {
                            $0.state = cancelled ? "cancelled" : "failed"
                            $0.error = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                        }
                    }
                }
            }
            guard let status = registry.status(id) else { throw HTTPError(.internalServerError) }
            return try json(status)
        }

        api.get("exports/:id") { _, ctx in
            guard let id = ctx.parameters.get("id"), let s = registry.status(id) else { throw HTTPError(.notFound) }
            return try json(s)
        }

        // Shows a folder export in the Finder (on the Mac).
        api.post("exports/:id/reveal") { req, ctx in
            guard LocalClient.isLocal(req) else { throw HTTPError(.forbidden) }
            guard let id = ctx.parameters.get("id"), let path = registry.get(id)?.folder else { throw HTTPError(.notFound) }
            try LocalClient.reveal(URL(fileURLWithPath: path, isDirectory: true), select: false)
            return Response(status: .noContent)
        }

        api.delete("exports/:id") { _, ctx in
            guard let id = ctx.parameters.get("id"), registry.get(id) != nil else { throw HTTPError(.notFound) }
            registry.update(id) { $0.cancelled = true }
            return Response(status: .noContent)
        }

        // The ZIP, streamed while the files are made (downloadable once).
        api.get("exports/:id/download") { _, ctx in
            guard let id = ctx.parameters.get("id"), let job = registry.get(id) else { throw HTTPError(.notFound) }
            guard registry.start(id) else { return errorResponse(.conflict, "This export was already downloaded.") }
            let service = exporter()
            let entries = job.entries
            let format = job.options.format
            let body = ResponseBody { writer in
                // the writer can't be captured by the sink: hand the bytes over through a stream
                let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(1 << 30))
                let producer = Task {
                    do {
                        let zip = ZipStream { data in continuation.yield(data) }
                        try await service.run(entries, format: format, write: { e, url, data in
                            if let url { try await zip.add(path: e.path, file: url, modified: e.modified) } else if let data {
                                try await zip.add(path: e.path, data: data, modified: e.modified)
                            }
                        }, progress: { n in registry.update(id) { $0.done = n } }, isCancelled: { registry.isCancelled(id) })
                        try await zip.finish()
                        registry.update(id) { $0.state = "done" }
                        continuation.finish()
                    } catch {
                        registry.update(id) {
                            $0.state = $0.cancelled ? "cancelled" : "failed"
                            $0.error = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                        }
                        continuation.finish(throwing: error)
                    }
                }
                do {
                    for try await data in stream { try await writer.write(ByteBuffer(data: data)) }
                    try await writer.finish(nil)
                } catch {
                    registry.update(id) { $0.cancelled = true }  // the browser went away: stop making files
                    producer.cancel()
                    throw error
                }
            }
            return Response(status: .ok, headers: [
                .contentType: "application/zip",
                .contentDisposition: "attachment; filename*=UTF-8''\(percentEncoded(job.name + ".zip"))",
                .cacheControl: "private, no-store",
            ], body: body)
        }
    }
}

enum ExportName {
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.string(from: d)
    }

    /// A file/folder name from a title: no slashes, colons, control characters or leading dots.
    static func clean(_ s: String) -> String? {
        var t = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while t.hasPrefix(".") { t.removeFirst() }
        return t.isEmpty ? nil : String(t.prefix(120))
    }
}
