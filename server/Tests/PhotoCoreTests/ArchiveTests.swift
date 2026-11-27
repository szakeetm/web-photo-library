import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct ArchiveTests {
    struct Env { let db: AppDatabase; let root: URL; let runner: JobRunner; let albums: AlbumService; let ids: [String] }

    /// a.jpg's sidecar says archived, b.jpg's doesn't, c.jpg has none.
    func env(archivedSidecar: Bool = true) throws -> Env {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("Library/a.jpg"), dateTimeOriginal: "2020:01:01 10:00:00", offset: "+01:00", color: (1, 0, 0))
        Fixtures.writeJPEG(to: root.appendingPathComponent("Library/b.jpg"), dateTimeOriginal: "2020:01:02 10:00:00", offset: "+01:00", color: (0, 1, 0))
        Fixtures.writeJPEG(to: root.appendingPathComponent("Library/c.jpg"), dateTimeOriginal: "2020:01:03 10:00:00", offset: "+01:00", color: (0, 0, 1))
        if archivedSidecar {
            try Data(#"{"title":"a.jpg","archived":true}"#.utf8).write(to: root.appendingPathComponent("Library/a.jpg.supplemental-metadata.json"))
        }
        try Data(#"{"title":"b.jpg","favorited":true}"#.utf8).write(to: root.appendingPathComponent("Library/b.jpg.json"))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        let ids = ["a", "b", "c"].map { try! FileHasher.sha256(url: root.appendingPathComponent("Library/\($0).jpg")) }
        return Env(db: db, root: root, runner: runner, albums: AlbumService(db: db, settings: settings), ids: ids)
    }

    func archived(_ e: Env) throws -> [Bool] {
        try e.ids.map { id in try e.db.writer.read { try #require(try Asset.fetchOne($0, key: id)).archived } }
    }

    @Test func sidecarArchivedIsParsed() {
        #expect(SidecarParser.parse(Data(#"{"archived":true}"#.utf8))?.archived == true)
        #expect(SidecarParser.parse(Data(#"{"favorited":true}"#.utf8))?.archived == nil)
    }

    @Test func scanArchivesFromTakeoutSidecar() throws {
        let e = try env()
        #expect(try archived(e) == [true, false, false])
        let cat = try e.db.writer.read { try CatalogService.catalogAssets($0, ids: nil) }
        #expect(cat.first { $0.id == e.ids[0] }?.arc == true)
        #expect(cat.first { $0.id == e.ids[1] }?.arc == nil)
    }

    @Test func userChoiceSurvivesReindex() throws {
        let e = try env()
        try e.albums.setArchived(ids: [e.ids[0]], archived: false)
        try e.albums.setArchived(ids: [e.ids[2]], archived: true)
        e.runner.enqueue(.reindex)
        e.runner.waitUntilIdle()
        #expect(try archived(e) == [false, false, true])
        #expect(try e.albums.applyTakeoutArchive() == 0)
        #expect(try archived(e) == [false, false, true])
    }

    /// Photos indexed before archiving existed: the sidecar-only pass archives them, once.
    @Test func backfillReadsSidecarsOnly() throws {
        let e = try env(archivedSidecar: false)
        #expect(try archived(e) == [false, false, false])
        // the sidecar now says archived (as if read by an older server that ignored the field)
        try Data(#"{"archived":true}"#.utf8).write(to: e.root.appendingPathComponent("Library/a.jpg.json"))
        e.runner.enqueue(.detectChanges)   // the image is unchanged, so its sidecar is noted but not applied
        e.runner.waitUntilIdle()
        try e.db.writer.write { try $0.execute(sql: "UPDATE file SET sidecarRelPath = 'Library/a.jpg.json' WHERE assetId = ?", arguments: [e.ids[0]]) }
        try e.albums.applyTakeoutArchiveOnce()
        #expect(try archived(e) == [true, false, false])
        // once only: a later unarchive by the user isn't undone at the next start
        try e.albums.setArchived(ids: [e.ids[0]], archived: false)
        try e.db.writer.write { try $0.execute(sql: "UPDATE asset SET archivedUserSet = 0 WHERE id = ?", arguments: [e.ids[0]]) }
        try e.albums.applyTakeoutArchiveOnce()
        #expect(try archived(e) == [false, false, false])
    }
}
