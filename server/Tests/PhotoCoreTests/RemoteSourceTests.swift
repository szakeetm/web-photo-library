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

    @Test func takeoutAlbumsOnARemoteAreListedAndTheChosenOnesImported() throws {
        let e = try env()
        // a Google Photos export: album folders with a metadata.json; others are no albums
        Fixtures.writeJPEG(to: e.remote.appendingPathComponent("Regular_albums/2023-04 Italy/c.jpg"), dateTimeOriginal: "2023:04:08 10:00:00", offset: "+02:00", color: (0, 0, 1))
        try Data(#"{"title":"2023-04-08 Easter trip to Italy"}"#.utf8).write(to: e.remote.appendingPathComponent("Regular_albums/2023-04 Italy/metadata.json"))
        Fixtures.writeJPEG(to: e.remote.appendingPathComponent("Special_albums/Archive/d.jpg"), dateTimeOriginal: "2022:01:01 10:00:00", offset: "+02:00", color: (1, 1, 0))
        try Data(#"{"title":"Archive"}"#.utf8).write(to: e.remote.appendingPathComponent("Special_albums/Archive/metadata.json"))
        Fixtures.writeJPEG(to: e.remote.appendingPathComponent("Special_albums/What I eat/f.jpg"), dateTimeOriginal: "2022:02:01 10:00:00", offset: "+02:00", color: (0, 1, 1))
        _ = try e.scan(budget: 0)   // originals leave the Mac; the sidecars (metadata.json) stay
        let albums = AlbumService(db: e.db, settings: e.settings, dataDir: e.dataDir)
        let found = try albums.takeoutAlbums()
        #expect(found.map(\.title) == ["2023-04-08 Easter trip to Italy", "Archive"])   // by path; no metadata.json, no album
        #expect(found.allSatisfy { $0.count == 1 && $0.missing == 1 && $0.albumId == nil })
        #expect(found[0].path == e.remote.path + "/Regular_albums/2023-04 Italy")
        #expect(try albums.list().isEmpty)   // nothing happens on its own

        #expect(try albums.importTakeoutAlbums(keys: [found[1].key]).created == 1)
        #expect(try albums.list().map(\.title) == ["Archive"])
        let after = try albums.takeoutAlbums()
        #expect(after[1].albumId != nil && after[1].missing == 0 && after[0].albumId == nil)
        #expect(try albums.importTakeoutAlbums(keys: [found[1].key]).created == 0)
    }

    @Test func aBatchFetchesOnlyItsOwnSidecars() {
        let dir = "Library/Photos from 2001"
        let byDir = [dir: ["a.jpg.json", "b.jpg.supplemental-metadata.json", "c.jpg.json", "z.jpg.json", "metadata.json"].map { dir + "/" + $0 }]
        let batch = ["a.jpg", "b.jpg", "c(1).jpg"].map { Rclone.RemoteFile(path: dir + "/" + $0, size: 1, mtime: 0) }
        // c(1).jpg's sidecar is "c.jpg(1).json", which isn't there: none for it
        #expect(RemoteScanner.sidecars(for: batch, in: byDir) == [
            "Library/Photos from 2001/a.jpg.json", "Library/Photos from 2001/b.jpg.supplemental-metadata.json",
            "Library/Photos from 2001/metadata.json",
        ])
    }

    @Test func originalsLeaveThisMacAndComeBackWhenNeeded() throws {
        let e = try env()
        _ = try e.scan(budget: 0)   // nothing kept after each batch
        let a = e.mirror.appendingPathComponent("2021/a.jpg")
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: e.mirror.appendingPathComponent("2021/a.jpg.json").path))   // sidecars stay
        let id = try #require(try e.db.writer.read { try String.fetchOne($0, sql: "SELECT assetId FROM file WHERE relPath = '2021/a.jpg'") })
        let originals = CatalogService(db: e.db, settings: e.settings).originals
        // clients are told the original must come from the remote first, without it being fetched
        #expect(try originals.pendingFetch(id: id) == e.source)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        let url = try #require(try originals.original(id: id))
        #expect(url.path == a.path)
        #expect(try originals.pendingFetch(id: id) == nil)   // here now
        #expect(try FileHasher.sha256(url: url) == id)
    }

    @Test func manyOriginalsArePrefetchedTogether() throws {
        let e = try env()
        _ = try e.scan(budget: 0)   // nothing kept
        let ids = try e.db.writer.read { try String.fetchAll($0, sql: "SELECT assetId FROM file WHERE root = ? ORDER BY relPath", arguments: [e.source.root]) }
        #expect(ids.count == 2)
        let originals = CatalogService(db: e.db, settings: e.settings).originals
        #expect(try ids.allSatisfy { try originals.pendingFetch(id: $0) == e.source })
        originals.prefetch(ids: ids, motionIds: [], isCancelled: { false })
        #expect(try ids.allSatisfy { try originals.pendingFetch(id: $0) == nil })
        for rel in ["2021/a.jpg", "2021/b.jpg"] {
            #expect(FileManager.default.fileExists(atPath: e.mirror.appendingPathComponent(rel).path))
        }
        // here already: nothing to do (and nothing breaks without rclone work)
        originals.prefetch(ids: ids, motionIds: [], isCancelled: { false })
        #expect(try originals.original(id: ids[0]) == e.mirror.appendingPathComponent("2021/a.jpg"))
    }

    @Test func aFileDeletedOnTheRemoteIsForgotten() throws {
        let e = try env()
        _ = try e.scan()
        try FileManager.default.removeItem(at: e.remote.appendingPathComponent("2021/b.jpg"))
        let (r, _) = try e.scan()
        #expect(r.removed == 1 && r.unchanged == 1, "\(r)")
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM asset WHERE missingSince IS NOT NULL") } == 1)
    }

    @Test func aFileFetchedButNotKeptIsNotFetchedAgainUntilItChanges() throws {
        let e = try env()
        let clip = e.remote.appendingPathComponent("2021/broken.mp4")
        try Data("not a movie".utf8).write(to: clip)
        let (first, _) = try e.scan()
        #expect(first.added == 2 && first.skipped == 1, "\(first)")
        // nothing new: the unreadable clip isn't fetched (or reported) again
        let (again, _) = try e.scan()
        #expect(again.skipped == 0 && again.added == 0 && again.unchanged == 3, "\(again)")
        // changed on the remote: looked at again
        try Data("still not a movie".utf8).write(to: clip)
        let (changed, _) = try e.scan()
        #expect(changed.skipped == 1, "\(changed)")
        // gone from the remote: forgotten
        try FileManager.default.removeItem(at: clip)
        _ = try e.scan()
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM remote_skip") } == 0)
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
