import Foundation
import GRDB
import Testing
@testable import PhotoCore

/// More library folders on the Mac, next to the library folder.
@Suite struct LocalFoldersTests {
    @Test func scansSeveralFoldersAndForgetsARemovedOne() throws {
        let library = Fixtures.tempDir(), extra = Fixtures.tempDir().appendingPathComponent("Scans 2003", isDirectory: true)
        Fixtures.writeJPEG(to: library.appendingPathComponent("a.jpg"), dateTimeOriginal: "2021:07:04 15:30:00", offset: "+02:00", color: (1, 0, 0))
        Fixtures.writeJPEG(to: extra.appendingPathComponent("Roll 1/b.jpg"), dateTimeOriginal: "2003:01:01 10:00:00", offset: "+01:00", color: (0, 1, 0))
        try FileManager.default.copyItem(at: library.appendingPathComponent("a.jpg"), to: extra.appendingPathComponent("a again.jpg"))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, library.path)
        let dataDir = Fixtures.tempDir()
        // overlapping folders are refused
        #expect(throws: LocalFolderError.self) { try LocalFolders.add(path: library.appendingPathComponent("sub").path, settings, dataDir: dataDir) }
        try FileManager.default.createDirectory(at: library.appendingPathComponent("sub"), withIntermediateDirectories: true)
        #expect(throws: LocalFolderError.self) { try LocalFolders.add(path: library.appendingPathComponent("sub").path, settings, dataDir: dataDir) }
        let f = try LocalFolders.add(path: extra.path, settings, dataDir: dataDir)
        #expect(f.title == "Scans 2003")

        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        // one photo in both folders is one photo
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM asset") } == 2)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM file WHERE root = ?", arguments: [f.root]) } == 2)
        #expect(try db.writer.read { try String.fetchOne($0, sql: "SELECT name FROM folder WHERE root = ? AND relPath = ''", arguments: [f.root]) } == "Scans 2003")
        let scans = try settings.get(.sourceScans)
        #expect(scans.first { $0.root == f.root }?.added == 2)
        #expect(scans.first { $0.root == Roots.library }?.added == 1)

        try LocalFolders.remove(id: f.id, db: db, settings)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM file") } == 1)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM asset WHERE missingSince IS NULL") } == 1)
        #expect(try settings.get(.sourceScans).allSatisfy { $0.root != f.root })
    }
}
