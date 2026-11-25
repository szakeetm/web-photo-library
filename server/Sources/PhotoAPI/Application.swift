import Foundation
import Hummingbird
import HTTPTypes
import PhotoCore

public let serverVersion = "0.1.0"
/// Version of the HTTP API contract. Bump whenever request/response shapes change.
/// Clients must match exactly; any other client gets 426 and reloads the current web app.
public let apiVersion = 1

public func buildApplication(services: Services, webRoot: URL?, port: Int) -> some ApplicationProtocol {
    let router = Router()
    router.middlewares.add(VersionMiddleware())
    router.middlewares.add(OwnerMiddleware(settings: services.settings))
    APIRoutes(services: services, webRoot: webRoot).register(on: router)
    let staticFiles = StaticFiles(root: webRoot)
    router.get("/") { req, ctx in try await staticFiles.serve(path: "/", context: ctx) }
    router.get("**") { req, ctx in try await staticFiles.serve(path: req.uri.path, context: ctx) }
    return Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "PhotoServer"))
}

/// Stamps every API response with the API/server versions and refuses clients built for another API version.
struct VersionMiddleware<Context: RequestContext>: RouterMiddleware {
    static var apiHeader: HTTPField.Name { HTTPField.Name("X-API-Version")! }
    static var serverHeader: HTTPField.Name { HTTPField.Name("X-Server-Version")! }
    static var clientHeader: HTTPField.Name { HTTPField.Name("X-Client-API-Version")! }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard request.uri.path.hasPrefix("/api/") else { return try await next(request, context) }
        var response: Response
        if let raw = request.headers[Self.clientHeader], Int(raw) != apiVersion,
           request.uri.path != "/api/health" {
            response = errorResponse(.upgradeRequired, "This app doesn't match the server. Please update.", updateRequired: true)
        } else {
            do { response = try await next(request, context) } catch let e as HTTPError {
                response = errorResponse(e.status, e.body ?? e.status.reasonPhrase)
            }
        }
        response.headers[Self.apiHeader] = String(apiVersion)
        response.headers[Self.serverHeader] = serverVersion
        return response
    }
}

/// When an owner login is configured, requests carrying a different Tailscale identity are rejected.
struct OwnerMiddleware<Context: RequestContext>: RouterMiddleware {
    let settings: SettingsStore
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if let owner = (try? settings.get(.ownerLogin)).flatMap({ $0 }), !owner.isEmpty {
            let login = request.headers[HTTPField.Name("Tailscale-User-Login")!]
            let proxied = request.headers[HTTPField.Name("X-Forwarded-For")!] != nil
            // Allowed: the owner via Tailscale, or direct local access on the Mac (not proxied, no identity).
            let allowed = login.map { $0.lowercased() == owner.lowercased() } ?? !proxied
            if !allowed { return Response(status: .forbidden) }
        }
        return try await next(request, context)
    }
}

/// Serves the built web app; unknown non-API paths fall back to index.html (SPA routing).
struct StaticFiles: Sendable {
    let root: URL?
    let fileIO = FileIO()

    func serve(path: String, context: some RequestContext) async throws -> Response {
        if path.hasPrefix("/api/") { throw HTTPError(.notFound) }
        guard let root else { throw HTTPError(.notFound) }
        let rootPath = root.standardizedFileURL.path
        let decoded = path.removingPercentEncoding ?? path
        let candidate = URL(fileURLWithPath: rootPath + decoded).standardizedFileURL
        var isDir: ObjCBool = false
        if candidate.path.hasPrefix(rootPath + "/"),
           FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue {
            let body = try await fileIO.loadFile(path: candidate.path, context: context)
            let immutable = decoded.hasPrefix("/_app/immutable/")
            return Response(status: .ok, headers: [
                .contentType: contentType(forExtension: candidate.pathExtension),
                .cacheControl: immutable ? "public, max-age=31536000, immutable" : "no-cache",
            ], body: body)
        }
        let index = root.appendingPathComponent("index.html").path
        let body = try await fileIO.loadFile(path: index, context: context)
        return Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8", .cacheControl: "no-cache"], body: body)
    }
}

private let extraTypes: [String: String] = [
    "heic": "image/heic", "heif": "image/heif", "hif": "image/heif", "avif": "image/avif", "webp": "image/webp",
    "dng": "image/x-adobe-dng", "cr2": "image/x-canon-cr2", "cr3": "image/x-canon-cr3", "nef": "image/x-nikon-nef",
    "arw": "image/x-sony-arw", "raf": "image/x-fuji-raf", "orf": "image/x-olympus-orf", "rw2": "image/x-panasonic-rw2",
    "webmanifest": "application/manifest+json", "mjs": "text/javascript", "wasm": "application/wasm",
]

func contentType(forExtension ext: String) -> String {
    let e = ext.lowercased()
    return extraTypes[e] ?? MediaType.getMediaType(forExtension: e)?.description ?? "application/octet-stream"
}
