import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct AlbumTests {
    struct Env { let db: AppDatabase; let root: URL; let runner: JobRunner; let albums: AlbumService; let catalog: CatalogService; let ids: [String] }

    func env() throws -> Env {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("Paris 2008/eiffel.jpg"), dateTimeOriginal: "2008:12:20 10:00:00", offset: "+01:00", color: (1, 0, 0))
        Fixtures.writeJPEG(to: root.appendingPathComponent("Paris 2008/louvre.jpg"), dateTimeOriginal: "2008:12:21 10:00:00", offset: "+01:00", color: (0, 1, 0))
        Fixtures.writeJPEG(to: root.appendingPathComponent("Home/cat.jpg"), dateTimeOriginal: "2020:01:01 10:00:00", offset: "+01:00", color: (0, 0, 1))
        try Data(#"{"title":"Párizs 2008","description":""}"#.utf8).write(to: root.appendingPathComponent("Paris 2008/metadata.json"))
        try Data(#"{"description":"Sleepy tabby"}"#.utf8).write(to: root.appendingPathComponent("Home/cat.jpg.json"))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        let ids = ["Paris 2008/eiffel.jpg", "Paris 2008/louvre.jpg", "Home/cat.jpg"].map { try! FileHasher.sha256(url: root.appendingPathComponent($0)) }
        return Env(db: db, root: root, runner: runner, albums: AlbumService(db: db, settings: settings),
                   catalog: CatalogService(db: db, settings: settings), ids: ids)
    }

    @Test func createAddRemoveReorder() throws {
        let e = try env()
        let a = try e.albums.create(title: "Best", assetIds: [e.ids[0], e.ids[2]])
        try e.albums.modify(id: a.id, add: [e.ids[1], e.ids[0]], remove: [], order: nil)
        #expect(try e.albums.members(id: a.id) == [e.ids[0], e.ids[2], e.ids[1]])
        try e.albums.modify(id: a.id, add: [], remove: [e.ids[2]], order: [e.ids[1], e.ids[0]])
        #expect(try e.albums.members(id: a.id) == [e.ids[1], e.ids[0]])
        try e.albums.update(id: a.id, title: "Favourites of 2008", coverAssetId: e.ids[0])
        let listed = try #require(try e.albums.list().first { $0.id == a.id })
        #expect(listed.title == "Favourites of 2008" && listed.count == 2 && listed.coverId == e.ids[0])
        try e.albums.delete(id: a.id)
        #expect(try e.albums.list().isEmpty)
    }

    @Test func membersSurviveMissingAndPurgeRemovesThem() throws {
        let e = try env()
        let a = try e.albums.create(title: "Cats", assetIds: [e.ids[2]])
        try FileManager.default.removeItem(at: e.root.appendingPathComponent("Home/cat.jpg"))
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        #expect(try e.albums.members(id: a.id) == [e.ids[2]])
        e.runner.enqueue(.purgeMissing)
        e.runner.waitUntilIdle()
        #expect(try e.albums.members(id: a.id).isEmpty)
    }

    @Test func takeoutImportIsIdempotent() throws {
        let e = try env()
        #expect(try e.albums.importTakeoutAlbums().created == 1)
        let again = try e.albums.importTakeoutAlbums()
        #expect(again.created == 0)
        let albums = try e.albums.list()
        #expect(albums.count == 1 && albums[0].title == "Párizs 2008" && albums[0].source == "takeout" && albums[0].count == 2)
        #expect(try e.albums.pendingTakeoutAlbums() == 0)
    }

    @Test func detectChangesHintsAtTakeoutAlbums() throws {
        let e = try env()
        #expect(e.runner.recent(limit: 1).first?.message?.contains("1 Google Takeout album") == true)
    }

    @Test func favoritesAreUserSet() throws {
        let e = try env()
        try e.albums.setFavorite(ids: [e.ids[0], e.ids[1]], favorite: true)
        let a = try #require(try e.db.writer.read { try Asset.fetchOne($0, key: e.ids[0]) })
        #expect(a.favorite && a.favoriteUserSet)
    }

    @Test func searchByNameFolderDescriptionAndAlbum() throws {
        let e = try env()
        _ = try e.albums.create(title: "Holiday picks", assetIds: [e.ids[1]])
        #expect(try e.albums.search("eiff") == [e.ids[0]])
        #expect(Set(try e.albums.search("paris")) == Set([e.ids[0], e.ids[1]]))
        #expect(try e.albums.search("tabby") == [e.ids[2]])
        #expect(try e.albums.search("holiday louvre") == [e.ids[1]])
        #expect(try e.albums.search("\"; DROP TABLE asset; --").isEmpty)
    }

    @Test func catalogIncludesAlbums() throws {
        let e = try env()
        let a = try e.albums.create(title: "Mix", assetIds: [e.ids[2], e.ids[0]])
        let snap = try e.catalog.catalog()
        #expect(snap.albums.first { $0.id == a.id }?.assetIds == [e.ids[2], e.ids[0]])
    }
}
