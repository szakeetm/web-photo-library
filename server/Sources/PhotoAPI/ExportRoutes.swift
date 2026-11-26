import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import PhotoCore

/// Exports in progress: a ZIP streamed to the browser, files written into a folder on this Mac, or
/// files the browser fetches one by one into a folder on its own computer ("files").
final class ExportRegistry: @unchecked Sendable {
    struct Job {
        let id: String
        let name: String
        let target: String
        let options: ExportOptions
        let entries: [ExportEntry]
        var state = "ready"          // ready | running | done | failed | cancelled
        var done = 0
        var error: String?
        var folder: String?
        var cancelled = false
        var skipped: [String] = []
        var touched = Date()
    }

    struct Status: Encodable {
        let id: String
        let name: String
        let state: String
        let done: Int
        let total: Int
        let bytes: Int64
        let error: String?
        let folder: String?
        /// files that weren't available (the first 100) and how many there were
        let skipped: [String]
        let skippedCount: Int
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]

    func add(_ job: Job) {
        lock.lock(); defer { lock.unlock() }
        // forget exports an hour after they were last used (one running on the server is kept)
        jobs = jobs.filter { $0.value.state == "running" || Date().timeIntervalSince($0.value.touched) < 3600 }
        jobs[job.id] = job
    }

    func get(_ id: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[id] }

    /// The job, marked as just used (a browser fetching files one by one keeps it alive).
    func touch(_ id: String) -> Job? {
        lock.lock(); defer { lock.unlock() }
        jobs[id]?.touched = Date()
        return jobs[id]
    }

    func update(_ id: String, _ change: (inout Job) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if var j = jobs[id] { change(&j); j.touched = Date(); jobs[id] = j }
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
        get(id).map {
            Status(id: $0.id, name: $0.name, state: $0.state, done: $0.done, total: $0.entries.count,
                   bytes: ExportSummary($0.entries).bytes, error: $0.error, folder: $0.folder,
                   skipped: Array($0.skipped.prefix(100)), skippedCount: $0.skipped.count)
        }
    }
}

/// Bytes handed from the file maker to the response, at most `capacity` chunks at a time: the maker
/// waits for a slow network instead of piling the export up in memory.
actor BoundedPipe {
    private var buffer: [Data] = []
    private let capacity: Int
    private var finished = false
    private var failure: Error?
    private var closed = false
    private var reader: CheckedContinuation<Data?, Error>?
    private var writers: [CheckedContinuation<Void, Error>] = []

    init(capacity: Int) { self.capacity = capacity }

    func send(_ data: Data) async throws {
        while buffer.count >= capacity && !closed {
            try await withCheckedThrowingContinuation { writers.append($0) }
        }
        if closed { throw CancellationError() }
        if let r = reader {
            reader = nil
            r.resume(returning: data)
        } else {
            buffer.append(data)
        }
    }

    /// No more data (or the maker failed with `error`).
    func finish(throwing error: Error? = nil) {
        finished = true
        failure = error
        if let r = reader {
            reader = nil
            if let error { r.resume(throwing: error) } else { r.resume(returning: nil) }
        }
    }

    /// The next chunk; nil at the end.
    func next() async throws -> Data? {
        if !buffer.isEmpty {
            let d = buffer.removeFirst()
            if !writers.isEmpty { writers.removeFirst().resume() }
            return d
        }
        if finished {
            if let failure { throw failure }
            return nil
        }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }

    /// The reader went away: a waiting or later `send` throws.
    func close() {
        closed = true
        for w in writers { w.resume(throwing: CancellationError()) }
        writers = []
    }

    var buffered: Int { buffer.count }
}

/// A ZIP downloaded to another device is made in one go and can't be resumed: above this, the browser
/// writes the files into a folder itself (or the export is made on the Mac).
enum ZipLimit {
    static let items = 1000
    static let bytes: Int64 = 5_000_000_000
    static func allows(_ s: ExportSummary) -> Bool { s.items <= items && s.bytes <= bytes }
    static let message = "A ZIP from another device is limited to 1,000 photos and videos or 5 GB. Export into a folder instead, or choose fewer."
}

extension APIRoutes {
    struct ExportRequest: Decodable {
        let options: ExportOptions
        /// "zip" (download), "folder" (on this Mac, local mode only) or "files" (the browser writes them
        /// into a folder on its own computer, fetching them one by one)
        let target: String
        let folder: String?
        let name: String?
    }

    struct ExportEstimate: Encodable {
        let files: Int
        let items: Int
        let bytes: Int64
        /// whether a ZIP may be made for this device (no limit on the Mac itself)
        let zip: Bool
        let zipLimitItems: Int
        let zipLimitBytes: Int64
    }

    struct ExportEntryInfo: Encodable {
        let path: String
        let bytes: Int64
        /// milliseconds since 1970
        let modified: Int64
        /// `bytes` is the file's exact size (copied as it is), not an estimate
        let exact: Bool
    }

    func registerExportRoutes(on api: RouterGroup<BasicRequestContext>) {
        let registry = ExportRegistry()
        let services = self.services
        @Sendable func exporter() -> ExportService {
            ExportService(db: services.db, catalog: services.catalog, edits: services.edits, ffmpeg: services.ffmpeg,
                          cacheDir: services.paths.cacheDir)
        }
        // files left behind by exports that were running when the server stopped
        try? FileManager.default.removeItem(at: services.paths.cacheDir.appendingPathComponent("exports/work", isDirectory: true))

        // How big an export would be, and whether this device may have it as a ZIP.
        api.post("exports/estimate") { req, ctx in
            guard let options = try? await req.decode(as: ExportOptions.self, context: ctx) else {
                return errorResponse(.badRequest, "Invalid export.")
            }
            let entries: [ExportEntry]
            do { entries = try await blocking { try exporter().plan(options) } } catch ExportError.empty {
                entries = []
            } catch let e as ExportError {
                return errorResponse(.badRequest, e.description)
            }
            let s = ExportSummary(entries)
            return try json(ExportEstimate(files: s.files, items: s.items, bytes: s.bytes,
                                           zip: LocalClient.isLocal(req) || ZipLimit.allows(s),
                                           zipLimitItems: ZipLimit.items, zipLimitBytes: ZipLimit.bytes))
        }

        api.post("exports") { req, ctx in
            guard let body = try? await req.decode(as: ExportRequest.self, context: ctx), ["zip", "folder", "files"].contains(body.target) else {
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
            let summary = ExportSummary(entries)
            if body.target == "zip" && !LocalClient.isLocal(req) && !ZipLimit.allows(summary) {
                return errorResponse(.badRequest, ZipLimit.message)
            }
            let id = UUID().uuidString.lowercased()
            let stamp = ExportName.stamp(Date())
            let name = ExportName.clean(body.name ?? "") ?? "Photos \(stamp)"

            if let folder {
                let target = folder.appendingPathComponent(name, isDirectory: true)
                // what's already there from an earlier run of the same export isn't written again
                let resume = ExportService.alreadyInFolder(target)
                let needed = try await blocking { entries.filter { !resume($0) }.reduce(Int64(0)) { $0 + $1.bytes } }
                if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   Double(needed) * 1.05 > Double(free) {
                    let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                    let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                    return errorResponse(.badRequest, "Not enough space: the export needs about \(n) and that disk has \(f) free.")
                }
                registry.add(.init(id: id, name: name, target: body.target, options: body.options, entries: entries, folder: target.path))
                // write in the background; the app polls GET /exports/:id
                guard registry.start(id) else { throw HTTPError(.conflict) }
                let service = exporter()
                Task.detached {
                    do {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                        try await service.run(entries, format: body.options.format, write: ExportService.writeToFolder(target),
                                              progress: { n in registry.update(id) { $0.done = n } },
                                              isCancelled: { registry.isCancelled(id) },
                                              skipped: { p in registry.update(id) { $0.skipped.append(p) } },
                                              alreadyThere: resume)
                        registry.update(id) { $0.state = "done" }
                    } catch {
                        let cancelled = registry.isCancelled(id)
                        registry.update(id) {
                            $0.state = cancelled ? "cancelled" : "failed"
                            $0.error = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                        }
                    }
                }
            } else {
                registry.add(.init(id: id, name: name, target: body.target, options: body.options, entries: entries))
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

        // The files of a "files" export, for the browser to write into a folder itself.
        api.get("exports/:id/entries") { _, ctx in
            guard let id = ctx.parameters.get("id"), let job = registry.touch(id), job.target == "files" else { throw HTTPError(.notFound) }
            return try json(job.entries.map {
                let exact = switch $0.source {
                case .original, .motion(_, false), .data: true
                case .edited, .motion(_, true): false
                }
                return ExportEntryInfo(path: $0.path, bytes: $0.bytes, modified: Int64(($0.modified.timeIntervalSince1970 * 1000).rounded()),
                                       exact: exact)
            })
        }

        // One file of a "files" export (410 when it isn't available: the browser skips it).
        api.get("exports/:id/entries/:n") { _, ctx in
            guard let id = ctx.parameters.get("id"), let n = ctx.parameters.get("n", as: Int.self),
                  let job = registry.touch(id), job.target == "files", job.entries.indices.contains(n) else { throw HTTPError(.notFound) }
            let entry = job.entries[n]
            let headers: HTTPFields = [
                .contentType: contentType(forExtension: (entry.path as NSString).pathExtension),
                .cacheControl: "private, no-store",
            ]
            if case .data(let data) = entry.source {
                return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
            }
            let service = exporter()
            let f: (url: URL, temporary: Bool)?
            do { f = try await renderLimiter.run { try await service.resolve(entry, format: job.options.format) } } catch where ExportService.isMissing(error) {
                return errorResponse(.gone, "Not available (moved or deleted since the last scan): \(entry.path)")
            }
            guard let f else { throw HTTPError(.notFound) }
            let url = f.url
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            let temporary = f.temporary
            let body = ResponseBody(contentLength: size) { writer in
                defer { if temporary { try? FileManager.default.removeItem(at: url) } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.readChunk(upToCount: 1 << 20), !chunk.isEmpty {
                    try await writer.write(ByteBuffer(data: chunk))
                }
                try await writer.finish(nil)
            }
            return Response(status: .ok, headers: headers, body: body)
        }

        // The ZIP, streamed while the files are made (downloadable once).
        api.get("exports/:id/download") { _, ctx in
            guard let id = ctx.parameters.get("id"), let job = registry.get(id), job.target == "zip" else { throw HTTPError(.notFound) }
            guard registry.start(id) else { return errorResponse(.conflict, "This export was already downloaded.") }
            let service = exporter()
            let entries = job.entries
            let format = job.options.format
            let body = ResponseBody { writer in
                // the writer can't be captured by the maker: hand the bytes over through a pipe that
                // holds a few MB, so the maker waits for a slow network
                let pipe = BoundedPipe(capacity: 8)
                let producer = Task {
                    do {
                        let zip = ZipStream { data in try await pipe.send(data) }
                        try await service.run(entries, format: format, write: { e, url, data in
                            if let url { try await zip.add(path: e.path, file: url, modified: e.modified) } else if let data {
                                try await zip.add(path: e.path, data: data, modified: e.modified)
                            }
                        }, progress: { n in registry.update(id) { $0.done = n } }, isCancelled: { registry.isCancelled(id) },
                           skipped: { p in registry.update(id) { $0.skipped.append(p) } })
                        try await zip.finish()
                        registry.update(id) { $0.state = "done" }
                        await pipe.finish()
                    } catch {
                        registry.update(id) {
                            $0.state = $0.cancelled ? "cancelled" : "failed"
                            $0.error = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                        }
                        await pipe.finish(throwing: error)
                    }
                }
                do {
                    while let data = try await pipe.next() { try await writer.write(ByteBuffer(data: data)) }
                    try await writer.finish(nil)
                } catch {
                    registry.update(id) { $0.cancelled = true }  // the browser went away: stop making files
                    await pipe.close()
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
