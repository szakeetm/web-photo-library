import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct CatalogDeltaTests {
    func env() throws -> (db: AppDatabase, root: URL, runner: JobRunner, catalog: CatalogService, albums: AlbumService) {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("A/x.jpg"), dateTimeOriginal: "2021:07:04 15:30:00")
        Fixtures.writeJPEG(to: root.appendingPathComponent("A/y.jpg"), dateTimeOriginal: "2022:01:01 10:00:00", color: (1, 0, 0))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        return (db, root, runner, CatalogService(db: db, settings: settings), AlbumService(db: db, settings: settings))
    }

    @Test func catalogHasStableId() throws {
        let e = try env()
        let a = try e.catalog.catalog().catalogId
        #expect(a.count == 32)
        #expect(try e.catalog.catalog().catalogId == a)
    }

    @Test func deltaContainsOnlyChangedAssets() throws {
        let e = try env()
        let snap = try e.catalog.catalog()
        let none = try e.catalog.changes(since: snap.seq, catalogId: snap.catalogId)
        #expect(!none.reset && none.assets.isEmpty && none.deleted.isEmpty && none.folders == nil && none.seq == snap.seq)

        let target = snap.assets[0].id
        try e.albums.setFavorite(ids: [target], favorite: true)
        let d = try e.catalog.changes(since: snap.seq, catalogId: snap.catalogId)
        #expect(!d.reset && d.assets.map(\.id) == [target] && d.assets[0].fav && d.deleted.isEmpty)
        #expect(d.seq > snap.seq && d.folders?.isEmpty == false && d.albums != nil)
    }

    @Test func deltaSendsOnlyChangedAlbumsAndNewLists() throws {
        let e = try env()
        let first = try e.albums.create(title: "One", assetIds: [])
        let second = try e.albums.create(title: "Two", assetIds: [])
        let snap = try e.catalog.catalog()

        try e.albums.update(id: second.id, title: "Two!", coverAssetId: nil)
        let d = try e.catalog.changes(since: snap.seq, catalogId: snap.catalogId, have: snap.hashes)
        #expect(d.albums?.map(\.title) == ["Two!"] && d.deletedAlbums == [])
        // nothing in folders/people/places changed: the client's copies are kept
        #expect(d.folders == nil && d.people == nil && d.places == nil && d.hashes == snap.hashes)
        // without hashes (or with stale ones) the lists come along
        let full = try e.catalog.changes(since: snap.seq, catalogId: snap.catalogId)
        #expect(full.folders?.isEmpty == false && full.people != nil && full.places != nil)

        try e.albums.delete(id: first.id)
        let gone = try e.catalog.changes(since: d.seq, catalogId: snap.catalogId, have: snap.hashes)
        #expect(gone.albums == [] && gone.deletedAlbums == [first.id])
    }

    @Test func compactingTheLogKeepsDeltasTheSame() throws {
        let e = try env()
        let snap = try e.catalog.catalog()
        for fav in [true, false, true] { try e.albums.setFavorite(ids: [snap.assets[0].id], favorite: fav) }
        let before = try e.catalog.changes(since: snap.seq, catalogId: snap.catalogId)
        #expect(try e.catalog.compactChangeLog() > 0)
        let after = try e.catalog.changes(since: snap.seq, catalogId: snap.catalogId)
        #expect(after.assets.map(\.id) == before.assets.map(\.id) && after.seq == before.seq)
    }

    @Test func removedFileIsReportedDeleted() throws {
        let e = try env()
        let snap = try e.catalog.catalog()
        try FileManager.default.removeItem(at: e.root.appendingPathComponent("A/y.jpg"))
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        let d = try e.catalog.changes(since: snap.seq, catalogId: snap.catalogId)
        #expect(d.deleted.count == 1 && d.assets.isEmpty)
        #expect(try e.catalog.catalog().assets.count == 1)
    }

    @Test func foreignOrFutureReplicaMustReset() throws {
        let e = try env()
        let snap = try e.catalog.catalog()
        #expect(try e.catalog.changes(since: snap.seq, catalogId: "other").reset)
        #expect(try e.catalog.changes(since: snap.seq + 100, catalogId: snap.catalogId).reset)
        #expect(try e.catalog.changes(since: snap.seq, catalogId: nil).reset)
    }
}
