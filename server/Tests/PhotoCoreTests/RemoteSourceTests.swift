import Foundation
import GRDB
import Testing
@testable import PhotoCore

/// Remote sources with the real rclone; a folder on this Mac stands in for the remote.
@Suite(.enabled(if: Rclone.locate() != nil, "rclone isn't installed"))
struct RemoteSourceTests {
    struct Env {
        let db: AppDatabase
        let settings: SettingsStore
        let dataDir: URL
        let remote: URL
        let source: RemoteSource
        let rclone: Rclone

        func scanner(budget: Int64 = 1_000_000_000) -> RemoteScanner {
            let s = RemoteScanner(db: db, source: source, dataDir: dataDir, rclone: rclone, serverTZ: TimeZone(identifier: "UTC")!,
                                  cacheBudget: budget)
            s.batchFiles = 1   // one file per batch: batches are exercised
            return s
        }
        func scan(budget: Int64 = 1_000_000_000) throws -> (ScanReport, [String]) {
            let rendered = LockedBox<[String]>([])
            let r = try scanner(budget: budget).detectChanges(progress: { _, _ in }, isCancelled: { false }) { made in
                rendered.mutate { $0 += made.map(\.id) }
                // the files are on this Mac while their images are made
                for m in made { #expect(FileManager.default.fileExists(atPath: m.url.path)) }
            }
            return (r, rendered.value)
        }
        var mirror: URL { RemoteSources.mirror(source.root, dataDir: dataDir) }
    }

    func env() throws -> Env {
        let remote = Fixtures.tempDir()
        Fixtures.writeJPEG(to: remote.appendingPathComponent("2021/a.jpg"), dateTimeOriginal: "2021:07:04 15:30:00", offset: "+02:00", color: (1, 0, 0))
        Fixtures.writeJPEG(to: remote.appendingPathComponent("2021/b.jpg"), dateTimeOriginal: "2021:08:01 10:00:00", offset: "+02:00", color: (0, 1, 0))
        try Data("{}".utf8).write(to: remote.appendingPathComponent("2021/a.jpg.json"))
        try Data("x".utf8).write(to: remote.appendingPathComponent("notes.txt"))
        let dataDir = Fixtures.tempDir()
        let db = try AppDatabase(path: dataDir.appendingPathComponent("library.sqlite").path)
        let settings = SettingsStore(db: db)
        let source = try RemoteSources.add(path: remote.path, settings)
        return Env(db: db, settings: settings, dataDir: dataDir, remote: remote, source: source, rclone: try #require(Rclone.locate()))
    }

    @Test func scansFetchingInBatchesAndRendersWhileHere() throws {
        let e = try env()
        let (r, rendered) = try e.scan()
        #expect(r.added == 2 && r.skippedOther == 1, "\(r)")
        #expect(rendered.count == 2)
        let rows = try e.db.writer.read { try FileRow.filter(Column("root") == e.source.root).fetchAll($0) }
        #expect(Set(rows.map(\.relPath)) == ["2021/a.jpg", "2021/b.jpg"])
        // the sidecar came along and was found
        #expect(rows.first { $0.relPath == "2021/a.jpg" }?.sidecarRelPath == "2021/a.jpg.json")
        #expect(try e.db.writer.read { try Folder.filter(Column("root") == e.source.root).fetchCount($0) } == 2)

        // nothing new: nothing fetched or rendered
        let (again, none) = try e.scan()
        #expect(again.unchanged == 2 && again.added == 0 && none.isEmpty, "\(again)")
    }

    @Test func originalsLeaveThisMacAndComeBackWhenNeeded() throws {
        let e = try env()
        _ = try e.scan(budget: 0)   // nothing kept after each batch
        let a = e.mirror.appendingPathComponent("2021/a.jpg")
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: e.mirror.appendingPathComponent("2021/a.jpg.json").path))   // sidecars stay
        let id = try #require(try e.db.writer.read { try String.fetchOne($0, sql: "SELECT assetId FROM file WHERE relPath = '2021/a.jpg'") })
        let url = try #require(try CatalogService(db: e.db, settings: e.settings).originals.original(id: id))
        #expect(url.path == a.path)
        #expect(try FileHasher.sha256(url: url) == id)
    }

    @Test func aFileDeletedOnTheRemoteIsForgotten() throws {
        let e = try env()
        _ = try e.scan()
        try FileManager.default.removeItem(at: e.remote.appendingPathComponent("2021/b.jpg"))
        let (r, _) = try e.scan()
        #expect(r.removed == 1 && r.unchanged == 1, "\(r)")
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM asset WHERE missingSince IS NOT NULL") } == 1)
    }

    @Test func theSamePhotoInTwoSourcesIsOnePhoto() throws {
        let e = try env()
        let library = Fixtures.tempDir()
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Trip"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: e.remote.appendingPathComponent("2021/a.jpg"), to: library.appendingPathComponent("Trip/a copy.jpg"))
        try e.settings.set(.libraryPath, library.path)
        _ = try LibraryScanner(db: e.db, root: library, serverTZ: TimeZone(identifier: "UTC")!).detectChanges(progress: { _, _ in }, isCancelled: { false })
        _ = try e.scan()
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM asset") } == 2)
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM file") } == 3)
        // the copy on this Mac is read first: nothing is fetched
        let id = try #require(try e.db.writer.read { try String.fetchOne($0, sql: "SELECT assetId FROM file WHERE relPath = 'Trip/a copy.jpg'") })
        #expect(try CatalogService(db: e.db, settings: e.settings).originals.original(id: id)?.path == library.appendingPathComponent("Trip/a copy.jpg").path)
    }

    @Test func backupsCheckRemoteSourcesBeforeRestoring() throws {
        let e = try env()
        _ = try e.scan()
        let dest = Fixtures.tempDir().appendingPathComponent("backup").path
        try e.settings.set(.backupDestination, dest)
        let backup = BackupService(db: e.db, settings: e.settings, paths: AppPaths(dataDir: e.dataDir), serverVersion: "test")
        try backup.backup()
        let ok = try backup.inspect(dest)
        #expect(ok.canRestore, "\(ok.checks)")
        #expect(ok.manifest?.sources.first { $0.kind == "rclone" }?.files == 2)
        // the remote folder moved
        try FileManager.default.moveItem(at: e.remote, to: e.remote.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString)"))
        let bad = try backup.inspect(dest)
        #expect(!bad.canRestore && bad.checks.contains { $0.title.hasPrefix("Source") && !$0.ok }, "\(bad.checks)")
    }

    @Test func removingASourceForgetsItsPhotos() throws {
        let e = try env()
        _ = try e.scan()
        try RemoteSources.remove(id: e.source.id, db: e.db, e.settings, dataDir: e.dataDir)
        #expect(try RemoteSources.all(e.settings).isEmpty)
        #expect(try e.db.writer.read { try FileRow.fetchCount($0) } == 0)
        #expect(try e.db.writer.read { try Folder.filter(Column("root") == e.source.root).fetchCount($0) } == 0)
        #expect(!FileManager.default.fileExists(atPath: e.mirror.path))
        #expect(e.source.title == URL(fileURLWithPath: e.source.path).lastPathComponent)
        #expect(RemoteSource(id: 1, path: "pcloud:Photos/Trips").title == "Trips")
        #expect(RemoteSource(id: 1, path: "pcloud:").title == "pcloud")
    }

    @Test func listsWithMillisecondTimes() throws {
        #expect(Rclone.date("2019-12-24T16:27:45Z") == 1_577_204_865)
        let t = try #require(Rclone.date("2026-11-26T13:55:22.123456789+01:00"))
        #expect(abs(t - 1_795_697_722.123) < 0.0005)
    }
}
