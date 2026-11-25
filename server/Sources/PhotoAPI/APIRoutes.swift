import Foundation
import Hummingbird
import HTTPTypes
import PhotoCore

struct ErrorBody: Encodable { let error: String }

func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.withoutEscapingSlashes]
    var buffer = ByteBuffer()
    buffer.writeBytes(try enc.encode(value))
    return Response(status: status, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
                    body: .init(byteBuffer: buffer))
}

func errorResponse(_ status: HTTPResponse.Status, _ message: String) -> Response {
    (try? json(ErrorBody(error: message), status: status)) ?? Response(status: status)
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
    let fileIO = FileIO()

    struct Health: Encodable { let ok: Bool; let version: String; let libraryConfigured: Bool }
    struct SettingsBody: Codable { var libraryPath: String?; var cacheDir: String?; var ownerLogin: String? }
    struct SettingsResponse: Encodable {
        let libraryPath: String?; let cacheDir: String?; let ownerLogin: String?
        let defaultCacheDir: String; let cacheBytes: Int64
    }
    struct Jobs: Encodable { let current: JobRow?; let recent: [JobRow] }
    struct Enqueued: Encodable { let id: Int64 }

    func register(on router: Router<BasicRequestContext>) {
        let api = router.group("api")

        api.get("health") { _, _ in
            try json(Health(ok: true, version: serverVersion,
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
            if let c = body.cacheDir {
                if c.isEmpty { try services.settings.set(.cacheDir, nil) } else {
                    do { try FileManager.default.createDirectory(atPath: c, withIntermediateDirectories: true) } catch {
                        return errorResponse(.badRequest, "Cannot create cache folder: \(c)")
                    }
                    try services.settings.set(.cacheDir, c)
                }
            }
            if let o = body.ownerLogin { try services.settings.set(.ownerLogin, o.isEmpty ? nil : o) }
            return try settingsResponse()
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
        return try json(SettingsResponse(libraryPath: try s.get(.libraryPath), cacheDir: try s.get(.cacheDir),
                                         ownerLogin: try s.get(.ownerLogin), defaultCacheDir: services.paths.defaultCacheDir.path,
                                         cacheBytes: services.derivatives().sizeOnDisk()))
    }
}
