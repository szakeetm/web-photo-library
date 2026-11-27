import Foundation
import GRDB
import Testing
@testable import PhotoCore

@Suite struct SourceWatcherTests {
    let lib = "/Volumes/X/Photos Library.photoslibrary"

    @Test func inAPhotosLibraryOnlyOriginalsRendersAndTheDatabaseCount() {
        func kind(_ rel: String) -> WatchPaths.Kind { WatchPaths.classify("\(lib)/\(rel)", root: lib, photos: true) }
        #expect(kind("originals/A/AAAA-1.heic") == .files)
        #expect(kind("resources/renders/A/AAAA-1_1_201_a.jpeg") == .files)
        #expect(kind("database/Photos.sqlite-wal") == .database)
        #expect(kind("database/Photos.sqlite") == .database)
        // Photos' own work: thumbnails, analysis, search index, locks
        #expect(kind("resources/derivatives/A/AAAA-1_1_105_c.jpeg") == .ignored)
        #expect(kind("private/com.apple.photoanalysisd/caches/x") == .ignored)
        #expect(kind("database/search/psi.sqlite") == .ignored)
        #expect(kind("database/Photos.sqlite-shm") == .ignored)
        #expect(kind("database/Photos.sqlite.lock") == .ignored)
        // case doesn't matter (APFS ignores it), other folders don't count
        #expect(WatchPaths.classify("/volumes/x/photos library.photoslibrary/ORIGINALS/a/b.heic", root: lib, photos: true) == .files)
        #expect(WatchPaths.classify("/Volumes/X/other/a.jpg", root: lib, photos: true) == .ignored)
    }

    @Test func inAFolderHiddenFilesAndTheServersDataDontCount() {
        let root = "/Users/me/Pictures"
        #expect(WatchPaths.classify("\(root)/2024/a.jpg", root: root, photos: false) == .files)
        #expect(WatchPaths.classify("\(root)/2024", root: root, photos: false) == .files)  // a folder renamed or removed
        #expect(WatchPaths.classify("\(root)/.DS_Store", root: root, photos: false) == .ignored)
        #expect(WatchPaths.classify("\(root)/2024/.a.jpg.partial", root: root, photos: false) == .ignored)
        #expect(WatchPaths.classify("\(root)/.Trash/a.jpg", root: root, photos: false) == .ignored)
        #expect(WatchPaths.classify("\(root)/Data/cache/x.heic", root: root, photos: false, excluding: ["/users/me/pictures/data"]) == .ignored)
    }

    @Test func scansOnceChangesAreQuietOrAtTheLatestAfterTheCap() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var d = WatchDebounce()
        #expect(!d.due(at: t0))
        d.record(.ignored, at: t0)
        #expect(!d.pending)
        d.record(.database, at: t0)
        #expect(d.pending && d.databaseOnly)
        #expect(!d.due(at: t0.addingTimeInterval(19)))
        #expect(d.due(at: t0.addingTimeInterval(20)))  // quiet for 20 s
        // a steady trickle (a change every 10 s) is still scanned after 2 minutes
        d.reset()
        for s in stride(from: 0.0, through: 200, by: 10) {
            let now = t0.addingTimeInterval(s)
            if d.due(at: now) {
                #expect(s == 120)
                break
            }
            d.record(.files, at: now)
        }
        #expect(!d.databaseOnly)
    }

    @Test func immediateSourcesStillGetADailySafetyScan() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scan = { (root: String, hours: Double) in SourceScan(root: root, at: now.addingTimeInterval(-hours * 3600), report: nil) }
        #expect(SourceRefresh.due(intervals: ["folder-1": 0], scans: [scan("folder-1", 23)], now: now).isEmpty)
        #expect(SourceRefresh.due(intervals: ["folder-1": 0], scans: [scan("folder-1", 25)], now: now) == ["folder-1"])
    }

    /// The real thing: FSEvents on a folder set to Immediate queues a scan once a new photo has settled.
    @Test(.timeLimit(.minutes(1))) func aNewPhotoInAWatchedFolderIsScanned() async throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a.jpg"), color: (1, 0, 0))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        try settings.set(.sourceRefreshMinutes, [Roots.library: SourceRefresh.immediate])
        runner.watcher.quiet = 1
        runner.watcher.tickEvery = 0.25
        runner.watcher.sync()
        try await Task.sleep(for: .seconds(1.5))  // the stream is running
        let count = { try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM file WHERE root = 'library'") } ?? 0 }
        #expect(try count() == 1)

        Fixtures.writeJPEG(to: root.appendingPathComponent("2024/b.jpg"), color: (0, 1, 0))
        // the new file is first left alone while it may still be being written, then picked up
        var found = false
        for _ in 0..<160 where !found {
            try await Task.sleep(for: .milliseconds(250))
            runner.waitUntilIdle()
            found = try count() == 2
        }
        #expect(found)
        let scans = runner.recent(limit: 10).filter { $0.kind == JobKind.detectChanges.rawValue && $0.target == Roots.library }
        #expect(!scans.isEmpty)

        // a hidden file doesn't start a scan
        let before = runner.recent(limit: 50).count
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try await Task.sleep(for: .seconds(2.5))
        #expect(runner.recent(limit: 50).count == before)
    }
}

extension SourceWatcherTests {
    /// The quick check sees what a scan imports, and not Photos' own background writes.
    @Test func photosFingerprintChangesOnlyWithWhatIsImported() throws {
        let library = Fixtures.tempDir().appendingPathComponent("P.photoslibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("database"), withIntermediateDirectories: true)
        let path = library.appendingPathComponent("database/Photos.sqlite").path
        try PhotosLibraryTests.makeDatabase(URL(fileURLWithPath: path), assets: [
            (1, "AAAA-1", "A", "AAAA-1.jpeg", "IMG_0001.JPG", false, false, false),
            (2, "BBBB-2", "B", "BBBB-2.jpeg", "IMG_0002.JPG", false, false, false),
        ], albums: [(10, "ALB-1", "Japan", 2, [1])])
        func change(_ sql: String) throws {
            let q = try DatabaseQueue(path: path)
            try q.write { try $0.execute(sql: sql) }
            try q.close()
        }
        let start = try PhotosLibraryReader.fingerprint(library)
        #expect(try PhotosLibraryReader.fingerprint(library) == start)
        // Photos' own work (here: a column the scan doesn't read) changes nothing
        try change("ALTER TABLE ZASSET ADD COLUMN ZANALYSISSTATE INTEGER; UPDATE ZASSET SET ZANALYSISSTATE = 7")
        #expect(try PhotosLibraryReader.fingerprint(library) == start)
        var seen = [start]
        for sql in ["UPDATE ZASSET SET ZTRASHEDSTATE = 1 WHERE Z_PK = 2",        // deleted
                    "UPDATE ZASSET SET ZDATECREATED = ZDATECREATED + 3600 WHERE Z_PK = 1",  // date changed
                    "UPDATE ZASSET SET ZLATITUDE = 47.5, ZLONGITUDE = 19 WHERE Z_PK = 1",  // placed
                    "INSERT INTO Z_34ASSETS VALUES (10, 2, 0)",                       // added to an album
                    "UPDATE ZGENERICALBUM SET ZTITLE = 'Japan 2024' WHERE Z_PK = 10"] {  // album renamed
            try change(sql)
            let now = try PhotosLibraryReader.fingerprint(library)
            #expect(!seen.contains(now), "\(sql)")
            seen.append(now)
        }
    }
}
