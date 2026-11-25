import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct VideoPosterTests {
    func store() -> DerivativeStore { DerivativeStore(cacheDir: Fixtures.tempDir().appendingPathComponent("cache")) }

    @Test func posterForH264() async throws {
        let src = Fixtures.tempDir().appendingPathComponent("clip.mov")
        try await Fixtures.writeVideo(to: src, width: 1280, height: 720, seconds: 2)
        let s = store()
        let made = try s.ensurePoster(id: "abcdef", source: src, format: .heic, ffmpeg: nil)
        let p = try #require(ImageProbe.probe(url: made.preview))
        #expect(p.width == 1280 && p.height == 720)
        let t = try #require(ImageProbe.probe(url: made.thumb))
        #expect(max(t.width, t.height) == 512)
        #expect(made.preview == s.url(id: "abcdef", kind: .preview, format: .heic))
        #expect(made.thumb == s.url(id: "abcdef", kind: .thumb, format: .heic))
    }

    @Test func posterRotated() async throws {
        let src = Fixtures.tempDir().appendingPathComponent("portrait.mov")
        try await Fixtures.writeVideo(to: src, width: 1280, height: 720, seconds: 1, rotate90: true)
        let made = try store().ensurePoster(id: "abcdef", source: src, format: .heic, ffmpeg: nil)
        let p = try #require(ImageProbe.probe(url: made.preview))
        #expect(p.width == 720 && p.height == 1280)
    }

    @Test func unreadableVideoThrows() throws {
        let src = Fixtures.tempDir().appendingPathComponent("junk.mov")
        try Data("not a video".utf8).write(to: src)
        #expect(throws: (any Error).self) { try store().ensurePoster(id: "abcdef", source: src, format: .heic, ffmpeg: nil) }
    }

    @Test(.enabled(if: FFmpeg.locate() != nil))
    func posterForVP9() throws {
        let ffmpeg = try #require(FFmpeg.locate())
        let src = Fixtures.tempDir().appendingPathComponent("vp9.webm")
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc=size=640x360:duration=1", "-c:v", "libvpx-vp9", src.path]
        try p.run(); p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        let made = try store().ensurePoster(id: "abcdef", source: src, format: .heic, ffmpeg: ffmpeg)
        let img = try #require(ImageProbe.probe(url: made.preview))
        #expect(img.width == 640 && img.height == 360)
    }

    @Test func renderVideoSetsBlurhash() async throws {
        let root = Fixtures.tempDir()
        try await Fixtures.writeVideo(to: root.appendingPathComponent("clip.mov"), width: 640, height: 360, seconds: 1)
        try verifyRender(root)
    }

    /// Synchronous GRDB access (the async overloads would otherwise be picked inside async tests).
    func verifyRender(_ root: URL) throws {
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let cache = store()
        let runner = JobRunner(db: db, settings: settings, derivatives: { cache }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        let id = try #require(try db.writer.read { try String.fetchOne($0, sql: "SELECT id FROM asset") })
        try db.writer.write { try $0.execute(sql: "UPDATE asset SET blurhash = NULL") }
        try runner.render(assetId: id, source: root.appendingPathComponent("clip.mov"), store: cache)
        let bh = try db.writer.read { try String.fetchOne($0, sql: "SELECT blurhash FROM asset WHERE id = ?", arguments: [id]) }
        #expect(bh != nil)
        #expect(cache.exists(id: id, kind: .thumb, format: .heic) && cache.exists(id: id, kind: .preview, format: .heic))
        #expect(try CatalogService(db: db, settings: settings).kind(id: id) == "video")
    }
}
