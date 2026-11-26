import Testing
import Foundation
import AVFoundation
import Hummingbird
import HTTPTypes
import HummingbirdTesting
@testable import PhotoAPI
@testable import PhotoCore

@Suite struct VideoAPITests {
    struct Env {
        let app: any ApplicationProtocol
        let services: Services
        let root: URL
    }

    /// A gray clip at 10 fps (AVAssetWriter writes a QuickTime container whatever the extension).
    static func writeVideo(_ url: URL, width: Int = 1280, height: Int = 720, codec: AVVideoCodecType = .h264,
                           seconds: Double = 1) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<Int(seconds * 10) {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            memset(CVPixelBufferGetBaseAddress(buf), 0x80, CVPixelBufferGetBytesPerRow(buf) * height)
            CVPixelBufferUnlockBaseAddress(buf, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    func env(ffmpeg: URL? = FFmpeg.locate(), _ make: (URL) async throws -> Void) async throws -> Env {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vapi-\(UUID().uuidString)")
        let root = base.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await make(root)
        let services = try Services(paths: AppPaths(dataDir: base.appendingPathComponent("data")),
                                    bootstrapDir: base.appendingPathComponent("boot"), inMemory: false, ffmpeg: ffmpeg)
        try services.settings.set(.libraryPath, root.path)
        services.jobs.enqueue(.detectChanges)
        services.jobs.waitUntilIdle()
        return Env(app: buildApplication(services: services, webRoot: nil, port: 0), services: services, root: root)
    }

    func asset(_ e: Env, _ name: String) throws -> CatalogAsset {
        try #require(try e.services.catalog.catalog().assets.first { $0.name == name })
    }

    func catalogEntry(_ client: some TestClientProtocol, _ id: String) async throws -> CatalogAsset? {
        try await client.execute(uri: "/api/catalog", method: .get) { res in
            try JSONDecoder().decode(CatalogSnapshot.self, from: Data(buffer: res.body)).assets.first { $0.id == id }
        }
    }

    func range(_ value: String) -> HTTPFields { [.range: value] }

    @Test func rangeForms() async throws {
        let e = try await env { APITests.writeJPEG($0.appendingPathComponent("IMG 1.jpg")) }
        let id = try asset(e, "IMG 1.jpg").id
        let file = try Data(contentsOf: e.root.appendingPathComponent("IMG 1.jpg"))
        let n = file.count
        try #require(n > 1000)
        let uri = "/api/assets/\(id)/original"
        try await e.app.test(.router) { client in
            try await client.execute(uri: uri, method: .get, headers: range("bytes=0-1")) { res in
                #expect(res.status == .partialContent)
                #expect(Data(buffer: res.body) == file.prefix(2))
                #expect(res.headers[.contentRange] == "bytes 0-1/\(n)")
                #expect(res.headers[.contentLength] == "2")
                #expect(res.headers[.acceptRanges] == "bytes")
            }
            try await client.execute(uri: uri, method: .get, headers: range("bytes=100-")) { res in
                #expect(res.status == .partialContent)
                #expect(Data(buffer: res.body) == file.dropFirst(100))
                #expect(res.headers[.contentRange] == "bytes 100-\(n - 1)/\(n)")
            }
            try await client.execute(uri: uri, method: .get, headers: range("bytes=-500")) { res in
                #expect(res.status == .partialContent)
                #expect(Data(buffer: res.body) == file.suffix(500))
                #expect(res.headers[.contentRange] == "bytes \(n - 500)-\(n - 1)/\(n)")
            }
            try await client.execute(uri: uri, method: .get, headers: range("bytes=\(n)-")) { res in
                #expect(res.status == .rangeNotSatisfiable)
                #expect(res.headers[.contentRange] == "bytes */\(n)")
            }
            try await client.execute(uri: uri, method: .get, headers: range("bytes=0-1,4-5")) { res in
                #expect(res.status == .ok && res.body.readableBytes == n)
            }
            try await client.execute(uri: uri, method: .get) { res in
                #expect(res.status == .ok)
                #expect(Data(buffer: res.body) == file)
                #expect(res.headers[.acceptRanges] == "bytes")
                #expect(res.headers[.contentType] == "image/jpeg")
                #expect(res.headers[.contentDisposition]?.contains("attachment") == true)
            }
        }
    }

    @Test func byteRangeEdgeCases() {
        #expect(ByteRange(header: nil, size: 10) == .full)
        #expect(ByteRange(header: "bytes=0-1", size: 10) == .partial(0...1))
        #expect(ByteRange(header: "bytes=2-99", size: 10) == .partial(2...9))     // end clamped
        #expect(ByteRange(header: "bytes=-99", size: 10) == .partial(0...9))      // suffix longer than the file
        #expect(ByteRange(header: "bytes=9-", size: 10) == .partial(9...9))
        #expect(ByteRange(header: "bytes=10-", size: 10) == .unsatisfiable)
        #expect(ByteRange(header: "bytes=-0", size: 10) == .unsatisfiable)
        #expect(ByteRange(header: "bytes=0-", size: 0) == .unsatisfiable)
        #expect(ByteRange(header: "bytes=5-2", size: 10) == .full)               // invalid: ignored
        #expect(ByteRange(header: "bytes=x-", size: 10) == .full)
        #expect(ByteRange(header: "items=0-1", size: 10) == .full)
        #expect(ByteRange(header: "bytes=0-1,4-5", size: 10) == .full)
    }

    @Test func originalPlanServesOriginal() async throws {
        let e = try await env { try await Self.writeVideo($0.appendingPathComponent("clip.mov")) }
        let id = try asset(e, "clip.mov").id
        let file = try Data(contentsOf: e.root.appendingPathComponent("clip.mov"))
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/assets/\(id)/video", method: .get) { res in
                #expect(res.status == .ok)
                #expect(res.headers[.contentType] == "video/quicktime")
                #expect(res.headers[.acceptRanges] == "bytes")
                #expect(Data(buffer: res.body) == file)
                #expect(res.headers[.cacheControl] == "private, max-age=3600")
                #expect(res.headers[.cacheControl]?.contains("immutable") == false)
            }
            try await client.execute(uri: "/api/assets/\(id)/video/status", method: .get) { res in
                #expect(String(buffer: res.body).contains(#""state":"ready""#))
            }
        }
    }

    @Test func videoETagRevalidates() async throws {
        let e = try await env { try await Self.writeVideo($0.appendingPathComponent("clip.mov")) }
        let id = try asset(e, "clip.mov").id
        let uri = "/api/assets/\(id)/video"
        try await e.app.test(.router) { client in
            let tag = try await client.execute(uri: uri, method: .get) { res in
                #expect(res.status == .ok)
                return try #require(res.headers[.eTag])
            }
            #expect(tag.hasPrefix("\"") && tag.hasSuffix("\""))
            try await client.execute(uri: uri, method: .get, headers: [.ifNoneMatch: tag]) { res in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
                #expect(res.headers[.eTag] == tag)
            }
            try await client.execute(uri: uri, method: .get, headers: [.ifNoneMatch: "\"0-0\""]) { res in
                #expect(res.status == .ok)
            }
            // A range for another version of the file gets the whole (current) file.
            try await client.execute(uri: uri, method: .get, headers: [.range: "bytes=0-1", .ifRange: "\"0-0\""]) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: uri, method: .get, headers: [.range: "bytes=0-1", .ifRange: tag]) { res in
                #expect(res.status == .partialContent)
            }
        }
    }

    @Test(.enabled(if: FFmpeg.locate() != nil))
    func previewNeededReturns202() async throws {
        let e = try await env { try await Self.writeVideo($0.appendingPathComponent("big.mov"), width: 1920, height: 1440, codec: .hevc) }
        let id = try asset(e, "big.mov").id
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/assets/\(id)/video", method: .get) { res in
                #expect(res.status == .accepted)
                #expect(String(buffer: res.body).contains(#""status":{"state":"#))
            }
            var ready = false
            for _ in 0..<300 where !ready {
                ready = try await client.execute(uri: "/api/assets/\(id)/video/status", method: .get) { res in
                    String(buffer: res.body).contains(#""state":"ready""#)
                }
                if !ready { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            #expect(ready)
            try await client.execute(uri: "/api/assets/\(id)/video", method: .get) { res in
                #expect(res.status == .ok)
                #expect(res.headers[.contentType] == "video/mp4")
                #expect(res.headers[.cacheControl] == "private, max-age=3600")
                #expect(res.headers[.eTag] != nil)
                #expect(Data(buffer: res.body) == (try? Data(contentsOf: e.services.videos.previewURL(id: id))))
            }
        }
    }

    @Test func noFFmpegFallbacks() async throws {
        let e = try await env(ffmpeg: nil) { root in
            try await Self.writeVideo(root.appendingPathComponent("big.mov"), width: 1920, height: 1440, codec: .hevc)
            try await Self.writeVideo(root.appendingPathComponent("odd.mov"), width: 320, height: 240)
        }
        let big = try asset(e, "big.mov").id
        let odd = try asset(e, "odd.mov").id
        try await e.services.db.writer.write {
            try $0.execute(sql: "UPDATE asset SET videoCodec = 'vp9', servePlan = 'preview' WHERE id = ?", arguments: [odd])
        }
        let file = try Data(contentsOf: e.root.appendingPathComponent("big.mov"))
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/assets/\(big)/video", method: .get) { res in
                #expect(res.status == .ok)
                #expect(res.headers[.contentType] == "video/quicktime")
                #expect(Data(buffer: res.body) == file)
            }
            try await client.execute(uri: "/api/assets/\(odd)/video", method: .get) { res in
                #expect(res.status == .conflict)
                #expect(String(buffer: res.body).contains(#""error":"unplayable""#))
            }
            try await client.execute(uri: "/api/assets/\(odd)/video/status", method: .get) { res in
                #expect(String(buffer: res.body).contains(#""state":"unavailable""#))
            }
            try await client.execute(uri: "/api/videos", method: .get) { res in
                let state = try JSONDecoder().decode(ConvertAllState.self, from: Data(buffer: res.body))
                #expect(state.ffmpeg == false && state.needed == 2)
            }
        }
    }

    @Test func motionServed() async throws {
        let e = try await env { root in
            APITests.writeJPEG(root.appendingPathComponent("IMG_1.jpg"))
            try await Self.writeVideo(root.appendingPathComponent("IMG_1.MP4"), width: 640, height: 480)
            try APITests().jpegBytes(color: 0.9).write(to: root.appendingPathComponent("IMG_2.jpg"))
        }
        let live = try asset(e, "IMG_1.jpg").id
        let still = try asset(e, "IMG_2.jpg").id
        let clip = try Data(contentsOf: e.root.appendingPathComponent("IMG_1.MP4"))
        try await e.app.test(.router) { client in
            #expect(try await catalogEntry(client, live)?.live == true)
            #expect(try await catalogEntry(client, still)?.live == nil)
            try await client.execute(uri: "/api/assets/\(live)/motion", method: .get, headers: range("bytes=0-1")) { res in
                #expect(res.status == .partialContent)
                #expect(res.headers[.contentType] == "video/mp4")
                #expect(Data(buffer: res.body) == clip.prefix(2))
                #expect(res.headers[.contentRange] == "bytes 0-1/\(clip.count)")
            }
            try await client.execute(uri: "/api/assets/\(still)/motion", method: .get) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test func catalogHasDuration() async throws {
        let e = try await env { root in
            try await Self.writeVideo(root.appendingPathComponent("clip.mov"), width: 320, height: 240, seconds: 2)
            APITests.writeJPEG(root.appendingPathComponent("photo.jpg"))
        }
        let video = try asset(e, "clip.mov").id
        let photo = try asset(e, "photo.jpg").id
        try await e.app.test(.router) { client in
            let dur = try #require(try await catalogEntry(client, video)?.dur)
            #expect(abs(dur - 2.0) < 0.15)
            #expect(dur == (dur * 10).rounded() / 10)
            #expect(try await catalogEntry(client, photo)?.dur == nil)
            try await client.execute(uri: "/api/catalog", method: .get) { res in
                #expect(String(buffer: res.body).contains("\"format\":8"))
            }
        }
    }

    @Test(.enabled(if: FFmpeg.locate() != nil))
    func convertAllRoutes() async throws {
        let e = try await env { root in
            for name in ["a", "b"] {
                try await Self.writeVideo(root.appendingPathComponent("\(name).mov"), width: 1920, height: 1440, codec: .hevc, seconds: 2)
            }
        }
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/videos/convert-all", method: .post) { res in
                #expect(res.status == .ok)
                let state = try JSONDecoder().decode(ConvertAllState.self, from: Data(buffer: res.body))
                #expect(state.state == "running" && state.total == 2 && state.ffmpeg)
            }
            try await client.execute(uri: "/api/videos/pause", method: .post) { res in
                #expect(res.status == .ok)
                let state = try JSONDecoder().decode(ConvertAllState.self, from: Data(buffer: res.body))
                #expect(state.state == "paused")
            }
            let state = try await client.execute(uri: "/api/videos", method: .get) { res in
                try JSONDecoder().decode(ConvertAllState.self, from: Data(buffer: res.body))
            }
            #expect(state.state == "paused")
        }
    }

    @Test func videosNotEditable() async throws {
        let e = try await env { try await Self.writeVideo($0.appendingPathComponent("clip.mov"), width: 320, height: 240) }
        let id = try asset(e, "clip.mov").id
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/assets/\(id)/edits", method: .post,
                                     body: ByteBuffer(string: #"{"recipe":{"schema":1,"exposure":0.5}}"#)) { res in
                #expect(res.status == .badRequest)
            }
            try await client.execute(uri: "/api/assets/\(id)/auto-enhance", method: .post) { res in
                #expect(res.status == .badRequest)
            }
            try await client.execute(uri: "/api/assets/\(id)/export", method: .get) { res in
                #expect(res.status == .badRequest)
            }
            try await client.execute(uri: "/api/gainmap/\(id)", method: .get) { res in
                #expect(res.status == .noContent)
            }
        }
        #expect(try e.services.catalog.catalogAsset(id: id)?.ev == 0)
    }

    @Test func videoThumbnails() async throws {
        let e = try await env { try await Self.writeVideo($0.appendingPathComponent("clip.mov"), width: 320, height: 240) }
        let id = try asset(e, "clip.mov").id
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/thumb/\(id)?fmt=jpeg", method: .get) { res in
                #expect(res.status == .ok)
                #expect(res.headers[.contentType] == "image/jpeg")
                #expect(res.body.readableBytes > 100)
            }
            try await client.execute(uri: "/api/thumb/\(id)?e=1", method: .get) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    /// A poster already on disk is served straight from the cache (no source lookup, no render queue).
    @Test func cachedVideoPosterServedDirectly() async throws {
        let e = try await env { try await Self.writeVideo($0.appendingPathComponent("clip.mov"), width: 320, height: 240) }
        let id = try asset(e, "clip.mov").id
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/preview/\(id)?fmt=jpeg", method: .get) { res in #expect(res.status == .ok) }
            try FileManager.default.removeItem(at: e.root.appendingPathComponent("clip.mov"))
            for kind in ["thumb", "preview"] {
                try await client.execute(uri: "/api/\(kind)/\(id)?fmt=jpeg", method: .get) { res in
                    #expect(res.status == .ok)
                    #expect(res.headers[.contentType] == "image/jpeg")
                }
            }
        }
    }
}
