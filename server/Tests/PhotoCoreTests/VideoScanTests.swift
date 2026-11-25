import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct VideoScanTests {
    final class Counter: @unchecked Sendable { var n = 0 }

    func make(_ root: URL, counter: Counter = Counter()) throws -> (AppDatabase, LibraryScanner) {
        let db = try AppDatabase.inMemory()
        return (db, scanner(db, root, counter: counter))
    }
    func scanner(_ db: AppDatabase, _ root: URL, counter: Counter = Counter()) -> LibraryScanner {
        LibraryScanner(db: db, root: root, serverTZ: TimeZone(identifier: "UTC")!) { url in
            counter.n += 1
            return try FileHasher.sha256(url: url)
        }
    }
    /// Scanning probes videos synchronously (blocking on AVFoundation); keep it off the cooperative pool.
    func gcd<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in DispatchQueue.global().async { c.resume(with: Result { try body() }) } }
    }
    func scan(_ s: LibraryScanner) async throws -> ScanReport {
        try await gcd { try s.detectChanges(progress: { _, _ in }, isCancelled: { false }) }
    }
    // Synchronous GRDB access (the async overloads would otherwise be picked inside async tests).
    func read<T>(_ db: AppDatabase, _ f: (Database) throws -> T) throws -> T { try db.writer.read(f) }
    func write<T>(_ db: AppDatabase, _ f: (Database) throws -> T) throws -> T { try db.writer.write(f) }
    func assets(_ db: AppDatabase) throws -> [Asset] { try read(db) { try Asset.fetchAll($0) } }
    func motions(_ db: AppDatabase) throws -> [MotionRow] { try read(db) { try MotionRow.fetchAll($0) } }

    @Test func videoIndexedAsAsset() async throws {
        let root = Fixtures.tempDir()
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/clip.mov"), width: 1280, height: 720, seconds: 2)
        let (db, s) = try make(root)
        let r = try await scan(s)
        #expect(r.added == 1 && r.skipped == 0 && r.skippedOther == 0)
        let all = try assets(db)
        #expect(all.count == 1)
        let a = try #require(all.first)
        #expect(a.kind == "video" && a.servePlan == "original" && a.videoCodec == "h264")
        #expect(abs((a.duration ?? 0) - 2) < 0.1)
        #expect(a.width == 1280 && a.height == 720)
        #expect(a.probeVersion == Asset.currentProbeVersion)
        #expect(a.iso == nil && a.aperture == nil && a.lens == nil)
        // A second scan neither rehashes nor re-adds it.
        let again = try await scan(s)
        #expect(again.unchanged == 1 && again.added == 0 && again.updated == 0)
    }

    @Test func sameNameMotionAttached() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a/IMG_1.jpg"))
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/IMG_1.MP4"), width: 640, height: 480)
        let (db, s) = try make(root)
        let r = try await scan(s)
        #expect(r.liveMotion == 1 && r.added == 1)
        let all = try assets(db)
        #expect(all.count == 1 && all.first?.kind == "photo")
        let m = try motions(db)
        #expect(m.count == 1)
        #expect(m.first?.relPath == "a/IMG_1.MP4" && m.first?.assetId == all.first?.id && m.first?.codec == "h264")
        #expect(try read(db) { try FileRow.fetchCount($0) } == 1)
        // Unchanged on rescan.
        let again = try await scan(s)
        #expect(again.liveMotion == 0 && again.unchanged == 1 && again.removed == 0)
        #expect(try motions(db).count == 1)
    }

    @Test func longSameNameVideoStaysVideo() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a/trip.jpg"))
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/trip.mov"), width: 320, height: 240, seconds: 8)
        let (db, s) = try make(root)
        let r = try await scan(s)
        #expect(r.liveMotion == 0 && r.added == 2)
        #expect(try motions(db).isEmpty)
        #expect(try assets(db).map(\.kind).sorted() == ["photo", "video"])
        // Stays a video on rescan.
        let again = try await scan(s)
        #expect(again.liveMotion == 0 && again.unchanged == 2)
        #expect(try motions(db).isEmpty)
    }

    @Test func sameNameDifferentContentIdStaysVideo() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a/IMG_5.jpg"))
        let (db, s) = try make(root)
        _ = try await scan(s)
        try write(db) { try $0.execute(sql: "UPDATE asset SET contentId = 'A'") }
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/IMG_5.mov"), width: 320, height: 240, contentId: "B")
        let r = try await scan(s)
        #expect(r.liveMotion == 0 && r.added == 1)
        #expect(try motions(db).isEmpty)
        #expect(try assets(db).contains { $0.kind == "video" && $0.contentId == "B" })
    }

    @Test func contentIdMatchIgnoresDuration() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a/IMG_6.heic"), type: .heic)
        let (db, s) = try make(root)
        _ = try await scan(s)
        try write(db) { try $0.execute(sql: "UPDATE asset SET contentId = 'L'") }
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/IMG_6.mov"), width: 320, height: 240, seconds: 8, contentId: "L")
        let r = try await scan(s)
        #expect(r.liveMotion == 1 && r.added == 0)
        #expect(try motions(db).count == 1)
    }

    @Test func stemMotionRule() {
        #expect(LibraryScanner.isStemMotion(duration: 3, videoContentId: nil, stillContentId: nil))
        #expect(LibraryScanner.isStemMotion(duration: 6.0, videoContentId: "A", stillContentId: nil))
        #expect(LibraryScanner.isStemMotion(duration: 2, videoContentId: "A", stillContentId: "A"))
        #expect(!LibraryScanner.isStemMotion(duration: 6.01, videoContentId: nil, stillContentId: nil))
        #expect(!LibraryScanner.isStemMotion(duration: nil, videoContentId: nil, stillContentId: nil))
        #expect(!LibraryScanner.isStemMotion(duration: 2, videoContentId: "A", stillContentId: "B"))
    }

    @Test func contentIdMotionAttached() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a/IMG_2.heic"), type: .heic)
        let (db, s) = try make(root)
        _ = try await scan(s)
        // ImageIO cannot write MakerApple; give the still its Live Photo id directly.
        try write(db) { try $0.execute(sql: "UPDATE asset SET contentId = 'X'") }
        let still = try #require(try assets(db).first)
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/other.mov"), width: 640, height: 480, contentId: "X")
        let r = try await scan(s)
        #expect(r.liveMotion == 1 && r.added == 0)
        #expect(try assets(db).count == 1)
        let m = try motions(db)
        #expect(m.count == 1 && m.first?.assetId == still.id && m.first?.relPath == "a/other.mov")
    }

    @Test func videoBecomesMotionWhenStillAppears() async throws {
        let root = Fixtures.tempDir()
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/IMG_3.mov"), width: 640, height: 480)
        let (db, s) = try make(root)
        _ = try await scan(s)
        let video = try #require(try assets(db).first)
        #expect(video.kind == "video")
        Fixtures.writeJPEG(to: root.appendingPathComponent("a/IMG_3.jpg"))
        let r = try await scan(s)
        #expect(r.liveMotion == 1)
        let after = try #require(try read(db) { try Asset.fetchOne($0, key: video.id) })
        #expect(after.missingSince != nil)
        let photo = try #require(try assets(db).first { $0.kind == "photo" })
        let m = try motions(db)
        #expect(m.count == 1 && m.first?.assetId == photo.id && m.first?.relPath == "a/IMG_3.mov")
        #expect(try read(db) { try FileRow.filter(Column("relPath") == "a/IMG_3.mov").fetchCount($0) } == 0)
    }

    @Test func videoBecomesMotionByContentIdWhenStillAppears() async throws {
        let root = Fixtures.tempDir()
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/clip.mov"), width: 640, height: 480, contentId: "Y")
        let (db, s) = try make(root)
        _ = try await scan(s)
        let video = try #require(try assets(db).first)
        #expect(video.kind == "video" && video.contentId == "Y")
        Fixtures.writeJPEG(to: root.appendingPathComponent("a/still.jpg"))
        _ = try await scan(s)  // indexes the still, without content id yet
        try write(db) { try $0.execute(sql: "UPDATE asset SET contentId = 'Y' WHERE kind = 'photo'") }
        let r = try await scan(s)
        #expect(r.liveMotion == 1)
        #expect(try read(db) { try Asset.fetchOne($0, key: video.id) }?.missingSince != nil)
        #expect(try motions(db).first?.relPath == "a/clip.mov")
    }

    @Test func motionRemovedWithFile() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a/IMG_1.jpg"))
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/IMG_1.MP4"), width: 640, height: 480)
        let (db, s) = try make(root)
        _ = try await scan(s)
        #expect(try motions(db).count == 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a/IMG_1.MP4"))
        _ = try await scan(s)
        #expect(try motions(db).isEmpty)
        #expect(try assets(db).first?.missingSince == nil)
    }

    @Test func motionBecomesVideoWhenStillDisappears() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a/IMG_1.jpg"))
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/IMG_1.MP4"), width: 640, height: 480)
        let (db, s) = try make(root)
        _ = try await scan(s)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a/IMG_1.jpg"))
        let r = try await scan(s)
        #expect(r.added == 1 && r.removed == 1)
        #expect(try motions(db).isEmpty)
        #expect(try assets(db).contains { $0.kind == "video" && $0.missingSince == nil })
    }

    @Test func duplicateMotionFirstWins() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a/IMG_1.jpg"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("a/IMG_1.jpg"), to: root.appendingPathComponent("b/IMG_1.jpg"))
        try await Fixtures.writeVideo(to: root.appendingPathComponent("a/IMG_1.MP4"), width: 640, height: 480)
        try FileManager.default.copyItem(at: root.appendingPathComponent("a/IMG_1.MP4"), to: root.appendingPathComponent("b/IMG_1.MP4"))
        let (db, s) = try make(root)
        _ = try await scan(s)
        #expect(try assets(db).count == 1)
        #expect(try motions(db).map(\.relPath) == ["a/IMG_1.MP4"])
        _ = try await scan(s)
        #expect(try motions(db).map(\.relPath) == ["a/IMG_1.MP4"])
    }

    @Test func oldPhotosReprobed() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a.jpg"))
        let c = Counter()
        let (db, s) = try make(root, counter: c)
        _ = try await scan(s)
        try write(db) {
            try $0.execute(sql: "UPDATE asset SET probeVersion = 0, contentId = NULL, favorite = 1, favoriteUserSet = 1, description = 'mine'")
        }
        let r = try await scan(s)
        #expect(r.updated == 1 && r.added == 0)
        #expect(c.n == 1)  // no rehash
        let a = try #require(try assets(db).first)
        #expect(a.probeVersion == 1)
        #expect(a.favorite && a.favoriteUserSet && a.description == "mine")
    }

    @Test func videoSidecarWins() async throws {
        let root = Fixtures.tempDir()
        try await Fixtures.writeVideo(to: root.appendingPathComponent("b/v.mov"), width: 640, height: 480,
                                      creationDate: "2024-08-03T07:53:00+02:00")
        try Data(#"{"photoTakenTime": {"timestamp": "1577836800"}}"#.utf8).write(to: root.appendingPathComponent("b/v.mov.json"))
        let (db, s) = try make(root)
        _ = try await scan(s)
        let a = try #require(try assets(db).first)
        #expect(a.takenAt == Date(timeIntervalSince1970: 1_577_836_800))
        #expect(a.dateSource == "sidecar")
        #expect(a.tzOffset == 7200)
    }

    @Test func videoEmbeddedDate() async throws {
        let root = Fixtures.tempDir()
        try await Fixtures.writeVideo(to: root.appendingPathComponent("v.mov"), width: 640, height: 480,
                                      creationDate: "2024-08-03T07:53:00+02:00")
        let (db, s) = try make(root)
        _ = try await scan(s)
        let a = try #require(try assets(db).first)
        #expect(a.takenAt == ISO8601DateFormatter().date(from: "2024-08-03T05:53:00Z"))
        #expect(a.dateSource == "exif" && a.tzOffset == 7200)
    }

    @Test func facesSkipVideos() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("p.jpg"))
        try await Fixtures.writeVideo(to: root.appendingPathComponent("v.mov"), width: 640, height: 480)
        let (db, s) = try make(root)
        _ = try await scan(s)
        let pending = try FaceService(db: db).pendingAssets()
        let kinds = try read(db) { d in try pending.map { try Asset.fetchOne(d, key: $0)!.kind } }
        #expect(kinds == ["photo"])
    }

    @Test func videoGetsPlace() async throws {
        let root = Fixtures.tempDir()
        try await Fixtures.writeVideo(to: root.appendingPathComponent("v.mov"), width: 640, height: 480, location: "+48.8566+002.3522/")
        let (db, s) = try make(root)
        _ = try await scan(s)
        #expect(try PlaceService(db: db).geocodePending() == 1)
        let a = try #require(try assets(db).first)
        #expect(a.placeId != nil && a.locationSource == "exif")
    }

    @Test func reindexRefreshesVideosAndMotion() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("IMG_1.jpg"))
        try await Fixtures.writeVideo(to: root.appendingPathComponent("IMG_1.mov"), width: 640, height: 480)
        try await Fixtures.writeVideo(to: root.appendingPathComponent("v.mov"), width: 640, height: 480)
        let (db, s) = try make(root)
        _ = try await scan(s)
        try write(db) {
            try $0.execute(sql: "UPDATE asset SET duration = NULL, videoError = 'boom' WHERE kind = 'video'")
            try $0.execute(sql: "UPDATE motion SET codec = NULL")
        }
        let r = try await gcd { try s.reindex(progress: { _, _ in }, isCancelled: { false }) }
        #expect(r.skipped == 0)
        let v = try #require(try assets(db).first { $0.kind == "video" })
        #expect(v.duration != nil && v.videoError == nil)
        #expect(try motions(db).first?.codec == "h264")
    }

    @Test func summaryMentionsLiveVideos() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a.jpg"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        try await gcd { runner.waitUntilIdle() }
        let msg = try #require(runner.recent(limit: 1).first?.message)
        #expect(msg.contains("1 other file skipped") || msg.contains("1 other files skipped"))
        #expect(!msg.contains("videos/other"))
    }

    @Test func motionURLValidatesFile() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("IMG_1.jpg"))
        let clip = root.appendingPathComponent("IMG_1.mov")
        try await Fixtures.writeVideo(to: clip, width: 640, height: 480)
        let (db, s) = try make(root)
        _ = try await scan(s)
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let catalog = CatalogService(db: db, settings: settings)
        let still = try #require(try assets(db).first)
        #expect(try catalog.motionURL(id: still.id)?.standardizedFileURL == clip.standardizedFileURL)
        #expect(try catalog.motionURL(id: "nope") == nil)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: clip.path)
        #expect(try catalog.motionURL(id: still.id) == nil)
    }

    @Test func purgeDeletesMotionOfPurgedStill() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("IMG_1.jpg"))
        try await Fixtures.writeVideo(to: root.appendingPathComponent("IMG_1.mov"), width: 640, height: 480)
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        try await gcd { runner.waitUntilIdle() }
        #expect(try motions(db).count == 1)
        try write(db) { try $0.execute(sql: "UPDATE asset SET missingSince = ?", arguments: [Date()]) }
        runner.enqueue(.purgeMissing)
        try await gcd { runner.waitUntilIdle() }
        #expect(try motions(db).isEmpty)
    }
}
