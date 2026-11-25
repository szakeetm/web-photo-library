import Testing
import Foundation
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoAPI
@testable import PhotoCore

@Suite struct APITests {
    struct Env {
        let app: any ApplicationProtocol
        let services: Services
        let root: URL
    }

    static func writeJPEG(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    func env(configured: Bool = true) throws -> Env {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString)")
        let root = base.appendingPathComponent("lib")
        Self.writeJPEG(root.appendingPathComponent("Trip/IMG 1.jpg"))
        let web = base.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: web.appendingPathComponent("_app"), withIntermediateDirectories: true)
        try Data("<html>index</html>".utf8).write(to: web.appendingPathComponent("index.html"))
        try Data("console.log(1)".utf8).write(to: web.appendingPathComponent("_app/x.js"))
        let services = try Services(paths: AppPaths(dataDir: base.appendingPathComponent("data"), defaultCacheDir: base.appendingPathComponent("cache")),
                                    inMemory: true)
        if configured { try services.settings.set(.libraryPath, root.path) }
        return Env(app: buildApplication(services: services, webRoot: web, port: 0), services: services, root: root)
    }

    func indexed(_ e: Env) -> String {
        e.services.jobs.enqueue(.detectChanges)
        e.services.jobs.waitUntilIdle()
        return try! e.services.catalog.catalog().assets[0].id
    }

    @Test func health() async throws {
        let e = try env(configured: false)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/health", method: .get) { res in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.contains("\"ok\":true") && body.contains("\"libraryConfigured\":false"))
            }
        }
    }

    @Test func settingsRoundTripAndValidation() async throws {
        let e = try env(configured: false)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/settings", method: .put, body: ByteBuffer(string: #"{"libraryPath":"\#(e.root.path)"}"#)) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/api/settings", method: .get) { res in
                #expect(String(buffer: res.body).contains(e.root.lastPathComponent))
            }
            try await client.execute(uri: "/api/settings", method: .put, body: ByteBuffer(string: #"{"libraryPath":"/nope/\#(UUID())"}"#)) { res in
                #expect(res.status == .badRequest)
                #expect(String(buffer: res.body).contains("error"))
            }
        }
    }

    @Test func fsList() async throws {
        let e = try env()
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/fs/list?path=\(e.root.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)", method: .get) { res in
                #expect(res.status == .ok && String(buffer: res.body).contains("\"name\":\"Trip\""))
            }
        }
    }

    @Test func jobsEndpoint() async throws {
        let e = try env()
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/jobs/detect-changes", method: .post) { res in #expect(res.status == .ok) }
            e.services.jobs.waitUntilIdle()
            try await client.execute(uri: "/api/jobs", method: .get) { res in
                #expect(String(buffer: res.body).contains("\"state\":\"done\""))
            }
            try await client.execute(uri: "/api/jobs/bogus", method: .post) { res in #expect(res.status == .badRequest) }
        }
    }

    @Test func catalogAndThumb() async throws {
        let e = try env()
        let id = indexed(e)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/catalog", method: .get) { res in
                #expect(String(buffer: res.body).contains(id))
            }
            try await client.execute(uri: "/api/thumb/\(id)?e=0&fmt=heic", method: .get) { res in
                #expect(res.status == .ok)
                #expect(res.headers[.contentType] == "image/heic")
                #expect(res.headers[.cacheControl]?.contains("immutable") == true)
                #expect(res.body.readableBytes > 100)
            }
            try await client.execute(uri: "/api/preview/\(id)?e=0&fmt=jpeg", method: .get) { res in
                #expect(res.status == .ok && res.headers[.contentType] == "image/jpeg")
            }
            try await client.execute(uri: "/api/thumb/\(String(repeating: "0", count: 64))", method: .get) { res in
                #expect(res.status == .notFound)
            }
            try await client.execute(uri: "/api/thumb/..%2F..%2Fetc", method: .get) { res in
                #expect(res.status == .notFound || res.status == .badRequest)
            }
        }
    }

    @Test func originalDownload() async throws {
        let e = try env()
        let id = indexed(e)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/assets/\(id)/original", method: .get) { res in
                #expect(res.status == .ok)
                #expect(res.headers[.contentDisposition]?.contains("IMG%201.jpg") == true)
            }
            try await client.execute(uri: "/api/assets/\(id)", method: .get) { res in
                #expect(String(buffer: res.body).contains("Trip/IMG 1.jpg"))
            }
        }
    }

    @Test func staticAndSpaFallback() async throws {
        let e = try env()
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/_app/x.js", method: .get) { res in
                #expect(String(buffer: res.body) == "console.log(1)")
            }
            try await client.execute(uri: "/folders/Trip", method: .get) { res in
                #expect(String(buffer: res.body) == "<html>index</html>")
            }
            try await client.execute(uri: "/../../etc/passwd", method: .get) { res in
                #expect(!String(buffer: res.body).contains("root:"))
            }
            try await client.execute(uri: "/api/nope", method: .get) { res in #expect(res.status == .notFound) }
        }
    }

    @Test func ownerLoginEnforced() async throws {
        let e = try env()
        try e.services.settings.set(.ownerLogin, "me@example.com")
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/health", method: .get, headers: [HTTPField.Name("Tailscale-User-Login")!: "other@example.com"]) { res in
                #expect(res.status == .forbidden)
            }
            try await client.execute(uri: "/api/health", method: .get, headers: [HTTPField.Name("Tailscale-User-Login")!: "me@example.com"]) { res in
                #expect(res.status == .ok)
            }
        }
    }
}
