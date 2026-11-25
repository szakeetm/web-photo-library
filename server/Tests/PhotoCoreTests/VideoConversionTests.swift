import Testing
import Foundation
import AVFoundation
import GRDB
@testable import PhotoCore

@Suite struct VideoConversionTests {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var n = 0
        func inc() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    struct Env {
        let db: AppDatabase
        let root: URL
        let cache: URL
        let conv: VideoConversions
    }

    func env(_ root: URL, ffmpeg: URL? = FFmpeg.locate()) throws -> Env {
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let cache = Fixtures.tempDir()
        let conv = VideoConversions(db: db, catalog: CatalogService(db: db, settings: settings), cacheDir: cache, ffmpeg: ffmpeg)
        return Env(db: db, root: root, cache: cache, conv: conv)
    }

    /// Scans `root` off the cooperative pool (video probing blocks).
    func scan(_ e: Env) async throws {
        let s = LibraryScanner(db: e.db, root: e.root, serverTZ: TimeZone(identifier: "UTC")!)
        _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<ScanReport, Error>) in
            DispatchQueue.global().async { c.resume(with: Result { try s.detectChanges(progress: { _, _ in }, isCancelled: { false }) }) }
        }
    }

    // Synchronous GRDB access (the async overloads would otherwise be picked inside async tests).
    func read<T>(_ db: AppDatabase, _ f: (Database) throws -> T) throws -> T { try db.writer.read(f) }
    func write<T>(_ db: AppDatabase, _ f: (Database) throws -> T) throws -> T { try db.writer.write(f) }
    func assets(_ db: AppDatabase) throws -> [Asset] { try read(db) { try Asset.order(Column("takenAt").desc).fetchAll($0) } }

    func waitFor(_ seconds: Double = 30, _ cond: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try !cond() {
            if Date() > deadline { Issue.record("timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func vp9(_ url: URL, seconds: Int = 1) throws {
        let p = Process()
        p.executableURL = FFmpeg.locate()
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:duration=\(seconds)", "-c:v", "libvpx-vp9", url.path]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try p.run(); p.waitUntilExit()
        try #require(p.terminationStatus == 0)
    }

    func tempFiles(_ cache: URL) -> [String] {
        let e = FileManager.default.enumerator(atPath: cache.path)
        return (e?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".tmp.mp4") }
    }

    // MARK: - Arguments

    func filter(_ args: [String]) -> String? {
        args.firstIndex(of: "-vf").map { args[$0 + 1] }
    }
    func pair(_ args: [String], _ a: String, _ b: String) -> Bool {
        zip(args, args.dropFirst()).contains { $0 == a && $1 == b }
    }
    let src = URL(fileURLWithPath: "/x/in.mov"), out = URL(fileURLWithPath: "/y/out.tmp.mp4")

    @Test func argumentsScale4K() {
        let a = VideoConversions.arguments(source: src, output: out, width: 3840, height: 2160, hdr: false)
        #expect(pair(a, "-tag:v", "hvc1"))
        #expect(pair(a, "-movflags", "+faststart"))
        #expect(pair(a, "-b:v", "4M"))
        #expect(pair(a, "-c:v", "hevc_videotoolbox"))
        #expect(pair(a, "-map_metadata", "-1"))
        #expect(pair(a, "-b:a", "128k"))
        #expect(filter(a)?.contains("scale=-2:1080") == true)
        #expect(!a.contains("main10"))
        #expect(a.last == out.path)
    }

    @Test func argumentsUseDisplaySize() {
        let portrait = VideoConversions.arguments(source: src, output: out, width: 1080, height: 1920, hdr: false)
        #expect(filter(portrait) == nil)
        let tall = VideoConversions.arguments(source: src, output: out, width: 2160, height: 3840, hdr: false)
        #expect(filter(tall)?.contains("scale=1080:-2") == true)
        let hd = VideoConversions.arguments(source: src, output: out, width: 1920, height: 1080, hdr: false)
        #expect(filter(hd) == nil)
    }

    @Test func argumentsHLG() {
        let a = VideoConversions.arguments(source: src, output: out, width: 3840, height: 2160, hdr: true)
        #expect(pair(a, "-profile:v", "main10"))
        #expect(pair(a, "-color_trc", "arib-std-b67"))
        #expect(pair(a, "-pix_fmt", "p010le"))
        #expect(pair(a, "-color_primaries", "bt2020"))
        #expect(pair(a, "-colorspace", "bt2020nc"))
    }

    @Test func statusJSON() throws {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        #expect(String(decoding: try enc.encode(VideoStatus.converting(0.4)), as: UTF8.self) == #"{"progress":0.4,"state":"converting"}"#)
        #expect(String(decoding: try enc.encode(VideoStatus.failed("x")), as: UTF8.self) == #"{"error":"x","state":"failed"}"#)
        #expect(String(decoding: try enc.encode(VideoStatus.ready), as: UTF8.self) == #"{"state":"ready"}"#)
        for s: VideoStatus in [.ready, .queued, .unavailable, .converting(0.25), .failed("bad")] {
            #expect(try JSONDecoder().decode(VideoStatus.self, from: try enc.encode(s)) == s)
        }
    }

    @Test func previewPaths() throws {
        let e = try env(Fixtures.tempDir(), ffmpeg: nil)
        #expect(e.conv.previewURL(id: "abcdef") == e.cache.appendingPathComponent("video/ab/abcdef.mp4"))
        #expect(e.conv.motionPreviewURL(id: "abcdef") == e.cache.appendingPathComponent("video/ab/abcdef.motion.mp4"))
    }

    @Test func leftoverTempDeletedOnInit() throws {
        let cache = Fixtures.tempDir()
        let dir = cache.appendingPathComponent("video/ab")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("abcdef.tmp.mp4"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("abcdef.mp4"))
        let db = try AppDatabase.inMemory()
        _ = VideoConversions(db: db, catalog: CatalogService(db: db, settings: SettingsStore(db: db)), cacheDir: cache, ffmpeg: nil)
        #expect(tempFiles(cache).isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("abcdef.mp4").path))
    }

    @Test func progressParsing() {
        #expect(VideoConversions.progress(line: "out_time_us=500000", duration: 2) == 0.25)
        #expect(VideoConversions.progress(line: "out_time_us=9000000", duration: 2) == 1)
        #expect(VideoConversions.progress(line: "out_time_us=N/A", duration: 2) == nil)
        #expect(VideoConversions.progress(line: "frame=12", duration: 2) == nil)
        #expect(VideoConversions.progress(line: "out_time_us=500000", duration: 0) == nil)
    }

    // MARK: - Status without ffmpeg

    func insertVideo(_ e: Env, id: String, relPath: String, servePlan: String, codec: String = "hevc",
                     width: Int = 1920, height: Int = 1440, duration: Double = 1) throws {
        let url = e.root.appendingPathComponent(relPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        try write(e.db) { d in
            var a = Asset.placeholder(id: id)
            a.kind = "video"; a.width = width; a.height = height; a.mime = "com.apple.quicktime-movie"
            a.servePlan = servePlan; a.videoCodec = codec; a.duration = duration
            try a.insert(d)
            var folder = try Folder.filter(Column("relPath") == "").fetchOne(d) ?? Folder(id: nil, relPath: "", parentId: nil, name: "")
            if folder.id == nil { try folder.insert(d) }
            var f = FileRow(id: nil, assetId: id, relPath: relPath, folderId: folder.id!,
                            size: (attrs[.size] as! NSNumber).int64Value,
                            mtime: (attrs[.modificationDate] as! Date).timeIntervalSince1970)
            try f.insert(d)
        }
    }

    @Test func unavailableWithoutFFmpeg() throws {
        let root = Fixtures.tempDir()
        try Data("x".utf8).write(to: root.appendingPathComponent("a.mov"))
        try Data("x".utf8).write(to: root.appendingPathComponent("b.mov"))
        let e = try env(root, ffmpeg: nil)
        try insertVideo(e, id: "aaaa01", relPath: "a.mov", servePlan: "preview")
        try insertVideo(e, id: "bbbb02", relPath: "b.mov", servePlan: "original")
        #expect(e.conv.request(id: "aaaa01") == .unavailable)
        #expect(e.conv.status(id: "aaaa01") == .unavailable)
        #expect(e.conv.request(id: "bbbb02") == .ready)
        e.conv.startAll()
        let s = e.conv.allState()
        #expect(s.state == "idle" && !s.ffmpeg && s.needed == 1 && s.converted == 0)
    }

    @Test func jobHooks() throws {
        let root = Fixtures.tempDir()
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let cache = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { cache })
        try write(db) { d in
            var a = Asset.placeholder(id: "dddd04"); a.missingSince = Date()
            try a.insert(d)
        }
        final class Calls: @unchecked Sendable { var purged: [String] = []; var cleared = 0 }
        let calls = Calls()
        runner.onPurge = { calls.purged += $0 }
        runner.onClearCaches = { calls.cleared += 1 }
        runner.enqueue(.purgeMissing)
        runner.enqueue(.rebuildCaches)
        runner.waitUntilIdle()
        #expect(calls.purged == ["dddd04"])
        #expect(calls.cleared == 1)
    }

    // MARK: - With ffmpeg

    @Test(.enabled(if: FFmpeg.locate() != nil))
    func convertsToPlayableMP4() async throws {
        let root = Fixtures.tempDir()
        try await Fixtures.writeVideo(to: root.appendingPathComponent("big.mov"), width: 1920, height: 1440, codec: .hevc, seconds: 1)
        let e = try env(root)
        try await scan(e)
        let a = try #require(try assets(e.db).first)
        #expect(a.servePlan == "preview")
        #expect(e.conv.request(id: a.id) != .ready)
        try await waitFor { e.conv.status(id: a.id) == .ready }
        let out = e.conv.previewURL(id: a.id)
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(tempFiles(e.cache).isEmpty)

        let p = Process()
        p.executableURL = FFmpeg.ffprobe(next: try #require(FFmpeg.locate()))
        p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_tag_string,width,height", "-of", "default=nw=1", out.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(text.contains("codec_tag_string=hvc1"))
        #expect(text.contains("width=1440"))
        #expect(text.contains("height=1080"))

        // Top-level atoms: moov before mdat (+faststart).
        let data = try Data(contentsOf: out)
        var atoms: [String] = []
        var i = 0
        while i + 8 <= data.count {
            let size = data[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            atoms.append(String(decoding: data[i + 4..<i + 8], as: UTF8.self))
            guard size >= 8 else { break }
            i += size
        }
        let moov = try #require(atoms.firstIndex(of: "moov")), mdat = try #require(atoms.firstIndex(of: "mdat"))
        #expect(moov < mdat)
        let after = try #require(try read(e.db) { try Asset.fetchOne($0, key: a.id) })
        #expect(after.videoError == nil)
        #expect(e.conv.allState().converted == 1 && e.conv.allState().needed == 0)
    }

    @Test(.enabled(if: FFmpeg.locate() != nil))
    func concurrentRequestsShareOneConversion() async throws {
        let root = Fixtures.tempDir()
        try await Fixtures.writeVideo(to: root.appendingPathComponent("big.mov"), width: 1920, height: 1440, codec: .hevc, seconds: 1)
        let e = try env(root)
        try await scan(e)
        let id = try #require(try assets(e.db).first?.id)
        let launches = Box()
        e.conv.onLaunch = { _ = launches.inc() }
        let start = DispatchSemaphore(value: 0)
        let answered = Box()
        for _ in 0..<2 {
            Thread.detachNewThread { start.wait(); e.conv.request(id: id); _ = answered.inc() }
        }
        start.signal(); start.signal()
        try await waitFor { answered.value == 2 }
        try await waitFor { e.conv.status(id: id) == .ready }
        #expect(e.conv.request(id: id) == .ready)
        #expect(launches.value == 1)
    }

    @Test(.enabled(if: FFmpeg.locate() != nil))
    func pauseAndResume() async throws {
        let root = Fixtures.tempDir()
        for name in ["a", "b", "c"] { try vp9(root.appendingPathComponent("\(name).webm")) }
        let e = try env(root)
        try await scan(e)
        let ids = try assets(e.db).map(\.id)
        #expect(ids.count == 3)
        // Hold the second launch until the test has paused.
        let launches = Box()
        let release = DispatchSemaphore(value: 0)
        e.conv.onLaunch = { if launches.inc() == 2 { release.wait() } }
        e.conv.startAll()
        #expect(e.conv.allState().state == "running")
        #expect(e.conv.allState().total == 3)
        try await waitFor { launches.value == 2 }
        #expect(e.conv.allState().done == 1)
        e.conv.pause()
        release.signal()
        try await waitFor { e.conv.allState().current == nil }
        let paused = e.conv.allState()
        #expect(paused.state == "paused" && paused.done == 1)
        let converted = ids.filter { FileManager.default.fileExists(atPath: e.conv.previewURL(id: $0).path) }
        #expect(converted.count == 1)
        #expect(tempFiles(e.cache).isEmpty)
        let first = try #require(converted.first)
        let firstDate = try FileManager.default.attributesOfItem(atPath: e.conv.previewURL(id: first).path)[.modificationDate] as? Date

        e.conv.startAll()
        #expect(e.conv.allState().total == 2)
        try await waitFor { let s = e.conv.allState(); return s.state == "idle" && s.done == s.total }
        #expect(launches.value == 4)
        for id in ids { #expect(e.conv.status(id: id) == .ready) }
        #expect(try FileManager.default.attributesOfItem(atPath: e.conv.previewURL(id: first).path)[.modificationDate] as? Date == firstDate)
        #expect(e.conv.allState().converted == 3 && e.conv.allState().needed == 0)
    }

    @Test(.enabled(if: FFmpeg.locate() != nil))
    func failureRecorded() async throws {
        let root = Fixtures.tempDir()
        var junk = Data(count: 4096)
        for i in junk.indices { junk[i] = UInt8.random(in: 0...255) }
        try junk.write(to: root.appendingPathComponent("junk.mov"))
        let e = try env(root)
        try insertVideo(e, id: "cccc03", relPath: "junk.mov", servePlan: "preview")
        e.conv.request(id: "cccc03")
        try await waitFor { if case .failed = e.conv.status(id: "cccc03") { return true }; return false }
        let a = try #require(try read(e.db) { try Asset.fetchOne($0, key: "cccc03") })
        #expect(a.videoError != nil)
        #expect(!FileManager.default.fileExists(atPath: e.conv.previewURL(id: "cccc03").path))
        #expect(tempFiles(e.cache).isEmpty)
        // Not retried on request.
        let launches = Box()
        e.conv.onLaunch = { _ = launches.inc() }
        if case .failed = e.conv.request(id: "cccc03") {} else { Issue.record("expected failed") }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(launches.value == 0)
    }

    @Test(.enabled(if: FFmpeg.locate() != nil))
    func stalledConversionFails() async throws {
        let root = Fixtures.tempDir()
        try vp9(root.appendingPathComponent("a.webm"))
        let e = try env(root)
        try await scan(e)
        let id = try #require(try assets(e.db).first?.id)
        e.conv.stallTimeout = 0
        e.conv.request(id: id)
        try await waitFor { if case .failed = e.conv.status(id: id) { return true }; return false }
        #expect(e.conv.status(id: id) == .failed("Conversion stalled"))
        #expect(tempFiles(e.cache).isEmpty)
    }

    @Test(.enabled(if: FFmpeg.locate() != nil))
    func motionConversion() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("IMG_1.jpg"))
        try vp9(root.appendingPathComponent("IMG_1.webm"))
        let e = try env(root)
        try await scan(e)
        let still = try #require(try assets(e.db).first)
        #expect(still.kind == "photo")
        try #require(try read(e.db) { try MotionRow.fetchOne($0, key: still.id) } != nil)
        #expect(e.conv.request(id: still.id, motion: true) != .ready)
        try await waitFor { e.conv.status(id: still.id, motion: true) == .ready }
        #expect(FileManager.default.fileExists(atPath: e.conv.motionPreviewURL(id: still.id).path))
        #expect(!FileManager.default.fileExists(atPath: e.conv.previewURL(id: still.id).path))
    }

    @Test(.enabled(if: FFmpeg.locate() != nil))
    func removeAndClear() async throws {
        let root = Fixtures.tempDir()
        try vp9(root.appendingPathComponent("a.webm"))
        let e = try env(root)
        try await scan(e)
        let id = try #require(try assets(e.db).first?.id)
        e.conv.request(id: id)
        try await waitFor { e.conv.status(id: id) == .ready }
        e.conv.remove(id: id)
        #expect(!FileManager.default.fileExists(atPath: e.conv.previewURL(id: id).path))
        e.conv.request(id: id)
        try await waitFor { e.conv.status(id: id) == .ready }
        try e.conv.clear()
        #expect(!FileManager.default.fileExists(atPath: e.cache.appendingPathComponent("video").path))
        #expect(e.conv.allState().converted == 0)
    }
}
