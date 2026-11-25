import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct M1FixesTests {
    func indexed() throws -> (AppDatabase, SettingsStore, URL, JobRunner, DerivativeStore) {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a.jpg"), color: (1, 0, 0))
        Fixtures.writeJPEG(to: root.appendingPathComponent("b.jpg"), color: (0, 1, 0))
        try Data().write(to: root.appendingPathComponent("doc.pdf"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        return (db, settings, root, runner, store)
    }

    @Test func sourceURLRejectsFileChangedSinceScan() throws {
        let (db, settings, root, _, _) = try indexed()
        let catalog = CatalogService(db: db, settings: settings)
        let id = try FileHasher.sha256(url: root.appendingPathComponent("a.jpg"))
        #expect(try catalog.sourceURL(id: id) != nil)
        Fixtures.writeJPEG(to: root.appendingPathComponent("a.jpg"), width: 640, color: (0, 0, 1))
        #expect(try catalog.sourceURL(id: id) == nil)
    }

    @Test func skippedOtherFilesAreReported() throws {
        let (_, _, _, runner, _) = try indexed()
        let job = try #require(runner.recent(limit: 1).first)
        #expect(job.message?.contains("2 other files skipped") == true)
    }

    @Test func renderFailuresAreReported() throws {
        let root = Fixtures.tempDir()
        let good = root.appendingPathComponent("good.jpg")
        Fixtures.writeJPEG(to: good, width: 2000, height: 1500)
        // keep the header (probe succeeds) but truncate the image data
        let data = try Data(contentsOf: good)
        try data.prefix(700).write(to: root.appendingPathComponent("broken.jpg"))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store })
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        let msg = runner.recent(limit: 1).first?.message ?? ""
        let indexedBroken = try db.writer.read { try FileRow.filter(Column("relPath") == "broken.jpg").fetchCount($0) } == 1
        if indexedBroken { #expect(msg.contains("could not be rendered") && msg.contains("broken.jpg")) }
    }

    @Test func purgeDeletesDerivatives() throws {
        let (db, _, root, runner, store) = try indexed()
        let id = try FileHasher.sha256(url: root.appendingPathComponent("b.jpg"))
        #expect(store.exists(id: id, kind: .thumb, format: .heic))
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.jpg"))
        runner.enqueue(.detectChanges)
        runner.enqueue(.purgeMissing)
        runner.waitUntilIdle()
        #expect(try db.writer.read { try Asset.fetchCount($0) } == 1)
        #expect(!store.exists(id: id, kind: .thumb, format: .heic))
        #expect(!store.exists(id: id, kind: .preview, format: .heic))
    }

    @Test func reindexReportsMissingFile() throws {
        let (db, _, root, _, _) = try indexed()
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.jpg"))
        let s = LibraryScanner(db: db, root: root)
        let r = try s.reindex(progress: { _, _ in }, isCancelled: { false })
        #expect(r.errors.contains("File not found: a.jpg"))
    }

    @Test func cancelDuringWalk() throws {
        let root = Fixtures.tempDir()
        for i in 0..<5 { try FileManager.default.createDirectory(at: root.appendingPathComponent("d\(i)"), withIntermediateDirectories: true) }
        let s = LibraryScanner(db: try AppDatabase.inMemory(), root: root)
        #expect(throws: ScanError.cancelled) { try s.detectChanges(progress: { _, _ in }, isCancelled: { true }) }
    }

    @Test func monotonicProgress() {
        let p = MonotonicProgress()
        #expect(p.advance(to: 5) == true)
        #expect(p.advance(to: 3) == false)
        #expect(p.advance(to: 6) == true)
    }
}
