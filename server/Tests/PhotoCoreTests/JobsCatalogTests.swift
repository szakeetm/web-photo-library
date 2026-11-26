import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct JobsCatalogTests {
    struct Env {
        let db: AppDatabase
        let root: URL
        let runner: JobRunner
        let catalog: CatalogService
        let derivatives: DerivativeStore
    }

    func env(withLibrary: Bool = true) throws -> Env {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("A/x.jpg"), dateTimeOriginal: "2021:07:04 15:30:00", offset: "+02:00")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("A/x.jpg"), to: root.appendingPathComponent("B/x.jpg"))
        Fixtures.writeJPEG(to: root.appendingPathComponent("B/y.jpg"), dateTimeOriginal: "2022:01:01 10:00:00", offset: "+00:00", color: (1, 0, 0))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        if withLibrary { try settings.set(.libraryPath, root.path) }
        let derivatives = DerivativeStore(cacheDir: root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString))
        let runner = JobRunner(db: db, settings: settings, derivatives: { derivatives }, serverTZ: TimeZone(identifier: "UTC")!)
        return Env(db: db, root: root, runner: runner, catalog: CatalogService(db: db, settings: settings), derivatives: derivatives)
    }

    @Test func detectChangesJobIndexesAndGeneratesDerivatives() throws {
        let e = try env()
        let id = e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        let job = try #require(e.runner.job(id: id))
        #expect(job.state == "done" && job.error == nil)
        let snap = try e.catalog.catalog()
        #expect(snap.assets.count == 2)
        for a in snap.assets {
            #expect(a.bh != nil)
            #expect(e.derivatives.exists(id: a.id, kind: .thumb, format: .heic))
            #expect(e.derivatives.exists(id: a.id, kind: .preview, format: .heic))
        }
    }

    @Test func catalogSortedNewestFirstWithFolders() throws {
        let e = try env()
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        let snap = try e.catalog.catalog()
        #expect(snap.assets.map(\.t) == ["2022-01-01T10:00:00Z", "2021-07-04T13:30:00Z"])
        #expect(snap.assets[1].folders.count == 2 && snap.assets[1].tz == 7200 && snap.assets[1].name == "x.jpg")
        #expect(snap.seq > 0)
    }

    @Test func catalogExcludesMissing() throws {
        let e = try env()
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        try FileManager.default.removeItem(at: e.root.appendingPathComponent("B/y.jpg"))
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        #expect(try e.catalog.catalog().assets.count == 1)
    }

    @Test func purgeMissingDeletes() throws {
        let e = try env()
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        try FileManager.default.removeItem(at: e.root.appendingPathComponent("B/y.jpg"))
        e.runner.enqueue(.detectChanges)
        e.runner.enqueue(.purgeMissing)
        e.runner.waitUntilIdle()
        #expect(try e.db.writer.read { try Asset.fetchCount($0) } == 1)
    }

    @Test func folderTreeCounts() throws {
        let e = try env()
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        let tree = try e.catalog.folderTree()
        let byPath = Dictionary(uniqueKeysWithValues: tree.map { ($0.relPath, $0) })
        #expect(byPath[""]?.count == 0 && byPath["A"]?.count == 1 && byPath["B"]?.count == 2)
        #expect(byPath["A"]?.parentId == byPath[""]?.id && byPath["B"]?.coverId != nil)
    }

    @Test func assetDetailAndSource() throws {
        let e = try env()
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        let id = try e.catalog.catalog().assets[1].id
        let d = try #require(try e.catalog.asset(id: id))
        #expect(d.files.sorted() == ["A/x.jpg", "B/x.jpg"])
        #expect(try e.catalog.originals.original(id: id)?.lastPathComponent == "x.jpg")
    }

    @Test func noLibraryFailsWithMessage() throws {
        let e = try env(withLibrary: false)
        let id = e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        let job = try #require(e.runner.job(id: id))
        #expect(job.state == "failed" && job.error?.contains("library") == true)
    }

    @Test func uploadsAloneAreASource() throws {
        let e = try env(withLibrary: false)
        let settings = SettingsStore(db: e.db)
        try settings.set(.uploadsPath, e.root.path)
        let id = e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        #expect(e.runner.job(id: id)?.state == "done")
        #expect(try e.catalog.catalog().assets.count == 2)
        let scan = try #require(try settings.get(.sourceScans).first { $0.root == Roots.uploads })
        #expect(scan.ok)
    }

    @Test func libraryFolderCanBeRemoved() throws {
        let e = try env()
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        #expect(try e.catalog.catalog().assets.count == 2)
        let settings = SettingsStore(db: e.db)
        try LocalFolders.removeLibrary(db: e.db, settings)
        #expect(try settings.get(.libraryPath) == nil)
        #expect(try e.catalog.catalog().assets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: e.root.appendingPathComponent("A/x.jpg").path))
    }

    @Test func unreadableLibraryFailsJobNotServer() throws {
        let e = try env()
        try SettingsStore(db: e.db).set(.libraryPath, "/nonexistent-\(UUID())")
        let id = e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        #expect(e.runner.job(id: id)?.state == "failed")
        #expect(e.runner.job(id: id)?.error?.contains("Full Disk Access") == true)
    }

    @Test func cancelledJob() throws {
        let e = try env()
        e.runner.pauseForTesting()
        let id = e.runner.enqueue(.detectChanges)
        e.runner.cancel(id: id)
        e.runner.resumeForTesting()
        e.runner.waitUntilIdle()
        #expect(e.runner.job(id: id)?.state == "cancelled")
    }

    @Test func rebuildCachesRegenerates() throws {
        let e = try env()
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        let id = try e.catalog.catalog().assets[0].id
        let u = e.derivatives.url(id: id, kind: .thumb, format: .heic)
        try FileManager.default.removeItem(at: u)
        e.runner.enqueue(.rebuildCaches)
        e.runner.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: u.path))
    }
}
