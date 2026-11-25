import Foundation
import Hummingbird
import HTTPTypes
import PhotoCore

struct ErrorBody: Encodable { let error: String; var updateRequired: Bool? = nil }

func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.withoutEscapingSlashes]
    var buffer = ByteBuffer()
    buffer.writeBytes(try enc.encode(value))
    return Response(status: status, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
                    body: .init(byteBuffer: buffer))
}

func errorResponse(_ status: HTTPResponse.Status, _ message: String, updateRequired: Bool? = nil) -> Response {
    (try? json(ErrorBody(error: message, updateRequired: updateRequired), status: status)) ?? Response(status: status)
}

/// Runs blocking work off the cooperative thread pool.
func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            cont.resume(with: Result { try work() })
        }
    }
}

struct APIRoutes {
    let services: Services
    let webRoot: URL?

    /// Build id of the served web app (SvelteKit writes _app/version.json).
    var webVersion: String? {
        guard let root = webRoot,
              let data = try? Data(contentsOf: root.appendingPathComponent("_app/version.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }
    let fileIO = FileIO()

    struct Health: Encodable {
        let ok: Bool; let version: String; let apiVersion: Int; let minClientApiVersion: Int
        let webVersion: String?; let libraryConfigured: Bool
    }
    struct SettingsBody: Codable { var libraryPath: String?; var ownerLogin: String? }
    struct SettingsResponse: Encodable {
        let libraryPath: String?; let ownerLogin: String?
        let dataDir: String; let cacheBytes: Int64; let databaseBytes: Int64
    }
    struct MoveBody: Decodable { let path: String }
    struct MoveResponse: Encodable { let dataDir: String; let restarting: Bool }
    struct Jobs: Encodable { let current: JobRow?; let recent: [JobRow] }
    struct Enqueued: Encodable { let id: Int64 }

    func register(on router: Router<BasicRequestContext>) {
        let api = router.group("api")

        api.get("health") { _, _ in
            try json(Health(ok: true, version: serverVersion, apiVersion: apiVersion, minClientApiVersion: minClientApiVersion,
                            webVersion: webVersion,
                            libraryConfigured: ((try? services.settings.get(.libraryPath)).flatMap { $0 }) != nil))
        }

        api.get("settings") { _, _ in try settingsResponse() }

        api.put("settings") { req, ctx in
            let body = try await req.decode(as: SettingsBody.self, context: ctx)
            if let p = body.libraryPath {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
                    return errorResponse(.badRequest, "Folder does not exist: \(p)")
                }
                guard (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil else {
                    return errorResponse(.badRequest, "Folder is not readable: \(p). Grant PhotoServer Full Disk Access.")
                }
                try services.settings.set(.libraryPath, p)
            }
            if let o = body.ownerLogin { try services.settings.set(.ownerLogin, o.isEmpty ? nil : o) }
            return try settingsResponse()
        }

        api.post("data/move") { req, ctx in
            let body = try await req.decode(as: MoveBody.self, context: ctx)
            if services.jobs.current() != nil { return errorResponse(.conflict, "Wait for the running job to finish first.") }
            let target = URL(fileURLWithPath: body.path, isDirectory: true)
            do {
                try await blocking {
                    try DataMover.move(db: services.db, from: services.paths, to: target, bootstrapDir: services.bootstrapDir)
                }
            } catch let e as DataMoveError {
                return errorResponse(.badRequest, e.description)
            }
            let restart = services.restart
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { restart() }
            return try json(MoveResponse(dataDir: target.path, restarting: true))
        }

        api.get("fs/list") { req, _ in
            let path = req.uri.queryParameters.get("path") ?? FileManager.default.homeDirectoryForCurrentUser.path
            do { return try json(try DirectoryBrowser.list(path)) } catch {
                return errorResponse(.badRequest, "Cannot list \(path)")
            }
        }

        api.post("jobs/:kind") { _, ctx in
            guard let kind = ctx.parameters.get("kind").flatMap(JobKind.init(rawValue:)) else {
                return errorResponse(.badRequest, "Unknown job kind")
            }
            return try json(Enqueued(id: services.jobs.enqueue(kind)))
        }
        api.delete("jobs/:kind") { _, ctx in
            guard let id = ctx.parameters.get("kind", as: Int64.self) else { return errorResponse(.badRequest, "Bad id") }
            services.jobs.cancel(id: id)
            return Response(status: .noContent)
        }
        api.get("jobs") { _, _ in
            try json(Jobs(current: services.jobs.current(), recent: services.jobs.recent(limit: 10)))
        }

        api.get("catalog") { _, _ in
            let snap = try await blocking { try services.catalog.catalog() }
            return try json(snap)
        }
        api.get("folders") { _, _ in try json(try services.catalog.folderTree()) }

        api.get("assets/:id") { _, ctx in
            guard let id = validId(ctx), let detail = try services.catalog.asset(id: id) else { throw HTTPError(.notFound) }
            return try json(detail)
        }

        api.get("assets/:id/original") { _, ctx in
            guard let id = validId(ctx), let url = try services.catalog.sourceURL(id: id) else { throw HTTPError(.notFound) }
            let body = try await fileIO.loadFile(path: url.path, context: ctx)
            let name = url.lastPathComponent
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_.~"))) ?? "photo"
            return Response(status: .ok, headers: [
                .contentType: contentType(forExtension: url.pathExtension),
                .contentDisposition: "attachment; filename*=UTF-8''\(encoded)",
                .cacheControl: "private, max-age=3600",
            ], body: body)
        }

        for kind in DerivativeKind.allCases {
            api.get("\(kind.rawValue)/:id") { req, ctx in try await derivative(kind, req, ctx) }
        }
    }

    func validId(_ ctx: BasicRequestContext) -> String? {
        guard let id = ctx.parameters.get("id"), id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        return id
    }

    func derivative(_ kind: DerivativeKind, _ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let id = validId(ctx) else { throw HTTPError(.notFound) }
        let format = req.uri.queryParameters.get("fmt").flatMap(ImageFormat.init(rawValue:)) ?? .heic
        let ev = req.uri.queryParameters.get("e", as: Int.self) ?? 0
        guard ev == 0 else { throw HTTPError(.notFound) }  // edited renders arrive with the editor milestone
        guard let source = try services.catalog.sourceURL(id: id) else { throw HTTPError(.notFound) }
        let store = services.derivatives()
        let url = try await blocking { try store.ensure(id: id, source: source, kind: kind, editVersion: ev, format: format) }
        let body = try await fileIO.loadFile(path: url.path, context: ctx)
        return Response(status: .ok, headers: [
            .contentType: format.mimeType,
            .cacheControl: "public, max-age=31536000, immutable",
        ], body: body)
    }

    func settingsResponse() throws -> Response {
        let s = services.settings
        let dbBytes = ["", "-wal"].reduce(Int64(0)) { sum, suffix in
            let attrs = try? FileManager.default.attributesOfItem(atPath: services.paths.databaseURL.path + suffix)
            return sum + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return try json(SettingsResponse(libraryPath: try s.get(.libraryPath), ownerLogin: try s.get(.ownerLogin),
                                         dataDir: services.paths.dataDir.path, cacheBytes: services.derivatives().sizeOnDisk(),
                                         databaseBytes: dbBytes))
    }
}
