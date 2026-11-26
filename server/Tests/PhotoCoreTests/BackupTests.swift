import Foundation
import GRDB
import Testing
@testable import PhotoCore

/// Backups with the real rclone, to a local folder standing in for the remote.
@Suite(.enabled(if: Rclone.locate() != nil, "rclone isn't installed"))
struct BackupTests {
    struct Env {
        let paths: AppPaths
        let db: AppDatabase
        let settings: SettingsStore
        let library: URL
        let uploads: URL
        let remote: String
        var service: BackupService { BackupService(db: db, settings: settings, paths: paths, serverVersion: "test") }
    }

    func env() throws -> Env {
        let library = Fixtures.tempDir()
        Fixtures.writeJPEG(to: library.appendingPathComponent("A/a.jpg"), dateTimeOriginal: "2021:07:04 15:30:00", offset: "+02:00", color: (1, 0, 0))
        Fixtures.writeJPEG(to: library.appendingPathComponent("B/b.jpg"), dateTimeOriginal: "2021:08:01 10:00:00", offset: "+02:00", color: (0, 1, 0))
        let uploads = Fixtures.tempDir()
        try Data("one".utf8).write(to: uploads.appendingPathComponent("one.jpg"))
        try FileManager.default.createDirectory(at: uploads.appendingPathComponent(".incoming"), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: uploads.appendingPathComponent(".incoming/x.part"))
        let paths = AppPaths(dataDir: Fixtures.tempDir())
        let db = try AppDatabase(path: paths.databaseURL.path)
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, library.path)
        try settings.set(.uploadsPath, uploads.path)
        let s = LibraryScanner(db: db, root: library, serverTZ: TimeZone(identifier: "UTC")!) { try FileHasher.sha256(url: $0) }
        _ = try s.detectChanges(progress: { _, _ in }, isCancelled: { false })
        try db.writer.write { try $0.execute(sql: "INSERT INTO album (id, title, createdAt) VALUES (1, 'Trip', ?)", arguments: [Date()]) }
        return Env(paths: paths, db: db, settings: settings, library: library, uploads: uploads,
                   remote: Fixtures.tempDir().appendingPathComponent("backup").path)
    }

    @Test func backsUpTheDatabaseAndUploadsOnly() throws {
        let e = try env()
        try e.settings.set(.backupDestination, e.remote)
        let r = try e.service.backup()
        #expect(r.ok && r.assets == 2 && r.albums == 1)
        #expect(r.uploadsFiles == 1 && r.uploadsCopied == 1)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: e.remote + "/library.sqlite"))
        #expect(fm.fileExists(atPath: e.remote + "/uploads/one.jpg"))
        #expect(!fm.fileExists(atPath: e.remote + "/uploads/.incoming"))   // hidden folders stay out
        #expect(!fm.fileExists(atPath: e.remote + "/cache"))
        let m = try BackupService.decoder.decode(BackupManifest.self, from: Data(contentsOf: URL(fileURLWithPath: e.remote + "/manifest.json")))
        #expect(m.assets == 2 && m.sources.first?.path == e.library.path && m.sources.first?.samples.count == 2)
        // the backup's database opens and holds the album
        let q = try DatabaseQueue(path: e.remote + "/library.sqlite")
        #expect(try q.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM album") } == 1)
        // the next backup only copies what's new
        try Data("two".utf8).write(to: e.uploads.appendingPathComponent("two.jpg"))
        let r2 = try e.service.backup()
        #expect(r2.uploadsCopied == 1 && r2.uploadsFiles == 2)
        #expect(try e.settings.get(.lastBackup) == r2)
    }

    @Test func aFailedBackupIsReportedAndRetriedSooner() throws {
        let e = try env()
        try e.settings.set(.backupDestination, "nosuchremote:folder")
        try e.settings.set(.backupEnabled, true)
        #expect(throws: (any Error).self) { try e.service.backup() }
        let last = try #require(try e.settings.get(.lastBackup))
        #expect(!last.ok && last.error != nil)
        #expect(try !e.service.isDue(now: last.startedAt.addingTimeInterval(600)))
        #expect(try e.service.isDue(now: last.startedAt.addingTimeInterval(3700)))
    }

    @Test func inspectingChecksTheLibraryIsStillThere() throws {
        let e = try env()
        try e.settings.set(.backupDestination, e.remote)
        try e.service.backup()
        let ok = try e.service.inspect(e.remote)
        #expect(ok.canRestore, "\(ok.checks)")
        #expect(ok.uploadsFiles == 1)
        // the library moved: restoring would point at a folder that isn't there
        let moved = e.library.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: e.library, to: moved)
        let bad = try e.service.inspect(e.remote)
        #expect(!bad.canRestore)
        #expect(bad.checks.contains { $0.title == "Library" && !$0.ok })
        // nothing there at all
        #expect(try !e.service.inspect(Fixtures.tempDir().path).canRestore)
    }

    @Test func restoreReplacesTheDatabaseAtTheNextStart() throws {
        let e = try env()
        try e.settings.set(.backupDestination, e.remote)
        try e.service.backup()
        // after the backup: an album is added and an upload is lost
        try e.db.writer.write { try $0.execute(sql: "INSERT INTO album (id, title, createdAt) VALUES (2, 'Later', ?)", arguments: [Date()]) }
        try FileManager.default.removeItem(at: e.uploads.appendingPathComponent("one.jpg"))
        try e.service.restore(e.remote)
        #expect(FileManager.default.fileExists(atPath: e.uploads.appendingPathComponent("one.jpg").path))
        try e.db.writer.close()

        // the next start
        #expect(try BackupService.applyStagedRestore(e.paths))
        let db = try AppDatabase(path: e.paths.databaseURL.path)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM album") } == 1)
        let kept = try FileManager.default.contentsOfDirectory(atPath: e.paths.dataDir.path).filter { $0.contains(".pre-restore-") }
        #expect(kept.contains { $0.hasSuffix(".bak") })
        #expect(try BackupService.finishRestore(e.paths, settings: SettingsStore(db: db)) == e.remote)
        #expect(try SettingsStore(db: db).get(.uploadsPath) == e.uploads.path)
        // nothing staged any more
        #expect(try !BackupService.applyStagedRestore(e.paths))
    }

    @Test func aBackupFromANewerServerIsRefused() throws {
        let e = try env()
        try e.settings.set(.backupDestination, e.remote)
        try e.service.backup()
        let url = URL(fileURLWithPath: e.remote + "/manifest.json")
        var m = try BackupService.decoder.decode(BackupManifest.self, from: Data(contentsOf: url))
        m.migrations.append("v99-from-the-future")
        try BackupService.encoder.encode(m).write(to: url)
        let i = try e.service.inspect(e.remote)
        #expect(!i.canRestore && i.checks.contains { $0.title == "Version" && !$0.ok })
        #expect(throws: BackupError.self) { try e.service.restore(e.remote) }
    }

    @Test func browsesAndMakesFolders() throws {
        let rclone = try #require(Rclone.locate())
        let root = Fixtures.tempDir().path
        try rclone.makeFolder(root + "/New folder")
        try rclone.makeFolder(root + "/b")
        #expect(try rclone.folders(root) == ["b", "New folder"])
        #expect(Rclone.join("pcloud:", "Photos") == "pcloud:Photos")
        #expect(Rclone.join("pcloud:Photos", "x") == "pcloud:Photos/x")
    }
}
