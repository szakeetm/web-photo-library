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
        let restarted: Flag
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
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
        try Data(#"{"version":"1795605986338"}"#.utf8).write(to: web.appendingPathComponent("_app/version.json"))
        let restarted = Flag()
        let services = try Services(paths: AppPaths(dataDir: base.appendingPathComponent("data")),
                                    bootstrapDir: base.appendingPathComponent("boot"), inMemory: false,
                                    restart: { restarted.set() })
        if configured { try services.settings.set(.libraryPath, root.path) }
        return Env(app: buildApplication(services: services, webRoot: web, port: 0), services: services, root: root, restarted: restarted)
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

    @Test func moveDataLocation() async throws {
        let e = try env()
        _ = indexed(e)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("moved-\(UUID().uuidString)")
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/data/move", method: .post, body: ByteBuffer(string: #"{"path":"\#(dest.path)"}"#)) { res in
                #expect(res.status == .ok)
            }
        }
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("library.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("cache/thumb").path))
        #expect(AppPaths.resolve(bootstrapDir: e.services.bootstrapDir).dataDir.path == dest.path)
        try await Task.sleep(for: .seconds(1))
        #expect(e.restarted.isSet)
    }

    @Test func everyApiResponseCarriesVersions() async throws {
        let e = try env()
        try await e.app.test(.router) { client in
            for uri in ["/api/health", "/api/catalog", "/api/nope"] {
                try await client.execute(uri: uri, method: .get) { res in
                    #expect(res.headers[HTTPField.Name("X-API-Version")!] == String(apiVersion), "\(uri)")
                    #expect(res.headers[HTTPField.Name("X-Server-Version")!] == serverVersion)
                }
            }
            try await client.execute(uri: "/api/health", method: .get) { res in
                let body = String(buffer: res.body)
                #expect(body.contains("\"apiVersion\":\(apiVersion)") && !body.contains("minClientApiVersion"))
                #expect(body.contains("\"webVersion\":\"1795605986338\""))
            }
            try await client.execute(uri: "/api/catalog", method: .get) { res in
                #expect(String(buffer: res.body).contains("\"format\":\(catalogFormat)"))
            }
        }
    }

    @Test func mismatchedClientGetsUpgradeRequired() async throws {
        let e = try env()
        try await e.app.test(.router) { client in
            for v in [apiVersion - 1, apiVersion + 1] {
                let h: HTTPFields = [HTTPField.Name("X-Client-API-Version")!: String(v)]
                try await client.execute(uri: "/api/catalog", method: .get, headers: h) { res in
                    #expect(res.status == .upgradeRequired, "client api \(v)")
                    #expect(String(buffer: res.body).contains("updateRequired"))
                }
            }
            let h: HTTPFields = [HTTPField.Name("X-Client-API-Version")!: "0"]
            // health must stay reachable so the client can learn what to do
            try await client.execute(uri: "/api/health", method: .get, headers: h) { res in #expect(res.status == .ok) }
            let ok: HTTPFields = [HTTPField.Name("X-Client-API-Version")!: String(apiVersion)]
            try await client.execute(uri: "/api/catalog", method: .get, headers: ok) { res in #expect(res.status == .ok) }
        }
    }

    @Test func libraryMayNotOverlapDataLocation() async throws {
        let e = try env(configured: false)
        let parent = e.services.paths.dataDir.deletingLastPathComponent().path
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/settings", method: .put, body: ByteBuffer(string: #"{"libraryPath":"\#(parent)"}"#)) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test func missingConfiguredDataLocationIsNotRecreated() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString)")
        let boot = base.appendingPathComponent("boot")
        let gone = base.appendingPathComponent("Volumes/Unplugged/PhotoData")
        try Bootstrap.save(BootstrapConfig(dataDir: gone.path), in: boot)
        let services = try Services(paths: AppPaths.resolve(bootstrapDir: boot), bootstrapDir: boot)
        #expect(services.dataLocationMissing)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func resetDataLocationWhenMissing() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString)")
        let boot = base.appendingPathComponent("boot")
        try Bootstrap.save(BootstrapConfig(dataDir: base.appendingPathComponent("gone").path), in: boot)
        let services = try Services(paths: AppPaths.resolve(bootstrapDir: boot), bootstrapDir: boot)
        let app = buildApplication(services: services, webRoot: nil, port: 0)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/settings", method: .get) { res in
                #expect(String(buffer: res.body).contains("\"dataLocationMissing\":true"))
            }
            try await client.execute(uri: "/api/data/reset", method: .post) { res in #expect(res.status == .ok) }
        }
        #expect(Bootstrap.load(from: boot).dataDir == nil)
    }

    @Test func ownerSetRefusesProxiedRequestsWithoutIdentity() async throws {
        let e = try env()
        try e.services.settings.set(.ownerLogin, "me@example.com")
        try await e.app.test(.router) { client in
            // came through tailscale serve (forwarded) but no user identity, e.g. a tagged device
            try await client.execute(uri: "/api/health", method: .get, headers: [HTTPField.Name("X-Forwarded-For")!: "100.64.0.9"]) { res in
                #expect(res.status == .forbidden)
            }
            // direct local access on the Mac
            try await client.execute(uri: "/api/health", method: .get) { res in #expect(res.status == .ok) }
        }
    }

    @Test func onDemandRenderLimiterCapsConcurrency() async throws {
        let limiter = AsyncLimiter(limit: 2)
        let peak = PeakCounter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 {
                g.addTask {
                    await limiter.run {
                        await peak.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await peak.leave()
                    }
                }
            }
        }
        #expect(await peak.max <= 2)
    }

    actor PeakCounter {
        var current = 0, max = 0
        func enter() { current += 1; max = Swift.max(max, current) }
        func leave() { current -= 1 }
    }

    @Test func uploadsFolderSettingValidated() async throws {
        let e = try env()
        let up = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try await e.app.test(.router) { client in
            // created if missing, then returned in settings
            try await client.execute(uri: "/api/settings", method: .put, body: ByteBuffer(string: #"{"uploadsPath":"\#(up.path)"}"#)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains(up.lastPathComponent))
            }
            #expect(FileManager.default.fileExists(atPath: up.path))
            // inside the library → refused
            try await client.execute(uri: "/api/settings", method: .put, body: ByteBuffer(string: #"{"uploadsPath":"\#(e.root.appendingPathComponent("up").path)"}"#)) { res in
                #expect(res.status == .badRequest)
            }
            // library inside the uploads folder → refused
            try await client.execute(uri: "/api/settings", method: .put, body: ByteBuffer(string: #"{"libraryPath":"\#(up.path)"}"#)) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    func jpegBytes(color: CGFloat) -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("u-\(UUID().uuidString).jpg")
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: color, green: 0.2, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:07:04 12:00:00", kCGImagePropertyExifOffsetTimeOriginal: "+02:00"]] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return try! Data(contentsOf: url)
    }

    @Test func uploadNewDuplicateAndGarbage() async throws {
        let e = try env()
        _ = indexed(e)
        let up = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: up, withIntermediateDirectories: true)
        try e.services.settings.set(.uploadsPath, up.path)
        let bytes = jpegBytes(color: 0.9)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/uploads?source=phone&name=IMG_9.jpg", method: .post, body: ByteBuffer(bytes: bytes)) { res in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.contains("\"duplicate\":false") && body.contains("IMG_9.jpg"))
            }
            #expect(FileManager.default.fileExists(atPath: up.appendingPathComponent("phone-uploads/2024-07/IMG_9.jpg").path))
            // same bytes again → duplicate, nothing new written
            try await client.execute(uri: "/api/uploads?source=desktop&name=other.jpg", method: .post, body: ByteBuffer(bytes: bytes)) { res in
                #expect(String(buffer: res.body).contains("\"duplicate\":true"))
            }
            #expect(!FileManager.default.fileExists(atPath: up.appendingPathComponent("desktop-uploads").path))
            // garbage → 415, nothing written
            try await client.execute(uri: "/api/uploads?source=phone&name=x.jpg", method: .post, body: ByteBuffer(string: "nope")) { res in
                #expect(res.status == .unsupportedMediaType)
            }
            #expect((try? FileManager.default.contentsOfDirectory(atPath: up.appendingPathComponent(".incoming").path))?.isEmpty ?? true)
        }
        let catalog = try e.services.catalog.catalog()
        #expect(catalog.assets.count == 2)
        let id = try FileHasher.sha256(url: up.appendingPathComponent("phone-uploads/2024-07/IMG_9.jpg"))
        #expect(e.services.derivatives().exists(id: id, kind: .thumb, format: .heic))
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/assets/\(id)", method: .head) { res in #expect(res.status == .ok) }
            try await client.execute(uri: "/api/assets/\(String(repeating: "a", count: 64))", method: .head) { res in #expect(res.status == .notFound) }
        }
    }

    @Test func uploadWithoutFolderIsRefused() async throws {
        let e = try env()
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/uploads?source=phone&name=a.jpg", method: .post, body: ByteBuffer(bytes: jpegBytes(color: 0.1))) { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test func albumsFavoritesSearchEndpoints() async throws {
        let e = try env()
        let id = indexed(e)
        try await e.app.test(.router) { client in
            var albumId = ""
            try await client.execute(uri: "/api/albums", method: .post, body: ByteBuffer(string: #"{"title":"Trip","assetIds":["\#(id)"]}"#)) { res in
                #expect(res.status == .ok)
                let obj = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as! [String: Any]
                albumId = String(describing: obj["id"]!)
                #expect(obj["count"] as? Int == 1)
            }
            try await client.execute(uri: "/api/albums/\(albumId)", method: .patch, body: ByteBuffer(string: #"{"title":"Trip 2024"}"#)) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/api/albums/\(albumId)/assets", method: .post, body: ByteBuffer(string: #"{"remove":["\#(id)"]}"#)) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/api/albums", method: .get) { res in
                #expect(String(buffer: res.body).contains("Trip 2024"))
            }
            try await client.execute(uri: "/api/assets", method: .patch, body: ByteBuffer(string: #"{"ids":["\#(id)"],"favorite":true}"#)) { res in
                #expect(res.status == .noContent)
            }
            try await client.execute(uri: "/api/catalog", method: .get) { res in
                let body = String(buffer: res.body)
                #expect(body.contains("\"fav\":true") && body.contains("\"albums\""))
            }
            try await client.execute(uri: "/api/search?q=IMG", method: .get) { res in
                #expect(String(buffer: res.body).contains(id))
            }
            try await client.execute(uri: "/api/albums/\(albumId)", method: .delete) { res in #expect(res.status == .noContent) }
            try await client.execute(uri: "/api/albums/999", method: .delete) { res in #expect(res.status == .notFound) }
            try await client.execute(uri: "/api/albums", method: .post, body: ByteBuffer(string: #"{"title":"  "}"#)) { res in
                #expect(res.status == .badRequest)
            }
        }
        #expect(apiVersion == 5)
    }

    @Test func concurrentSameContentUploadsWriteOneCopy() async throws {
        let e = try env()
        let up = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: up, withIntermediateDirectories: true)
        try e.services.settings.set(.uploadsPath, up.path)
        let bytes = jpegBytes(color: 0.55)
        try await e.app.test(.live) { client in
            try await withThrowingTaskGroup(of: Void.self) { g in
                for _ in 0..<4 {
                    g.addTask {
                        try await client.execute(uri: "/api/uploads?source=phone&name=same.jpg", method: .post, body: ByteBuffer(bytes: bytes)) { res in
                            #expect(res.status == .ok)
                        }
                    }
                }
                try await g.waitForAll()
            }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: up.appendingPathComponent("phone-uploads/2024-07").path)
        #expect(files == ["same.jpg"])
    }

    @Test func uploadWithOddNameSurvivesRescan() async throws {
        let e = try env()
        let up = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: up, withIntermediateDirectories: true)
        try e.services.settings.set(.uploadsPath, up.path)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/uploads?source=phone&name=photo.jfif", method: .post, body: ByteBuffer(bytes: jpegBytes(color: 0.66))) { res in
                #expect(res.status == .ok)
            }
        }
        e.services.jobs.enqueue(.detectChanges)
        e.services.jobs.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: up.appendingPathComponent("phone-uploads/2024-07/photo.jpeg").path))
        #expect(try e.services.catalog.catalog().assets.count == 2)
    }

    @Test func uploadsFolderThroughSymlinkIntoLibraryIsRefused() async throws {
        let e = try env()
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: e.root)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/settings", method: .put, body: ByteBuffer(string: #"{"uploadsPath":"\#(link.appendingPathComponent("Uploads").path)"}"#)) { res in
                #expect(res.status == .badRequest)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: e.root.appendingPathComponent("Uploads").path))
    }

    @Test func healthReportsUploadsConfigured() async throws {
        let e = try env()
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/health", method: .get) { res in
                #expect(String(buffer: res.body).contains("\"uploadsConfigured\":false"))
            }
        }
    }
}
