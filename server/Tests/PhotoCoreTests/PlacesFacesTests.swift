import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct PlacesTests {
    @Test func reverseGeocodesKnownCities() throws {
        let g = try Geocoder.shared()
        let salzburg = try #require(g.place(lat: 47.79431, lon: 13.05635))
        #expect(salzburg.name == "Salzburg" && salzburg.countryCode == "AT" && salzburg.country == "Austria")
        #expect(salzburg.region == "Salzburg")
        let budapest = try #require(g.place(lat: 47.4979, lon: 19.0402))
        #expect(budapest.name == "Budapest" && budapest.country == "Hungary")
        #expect(g.place(lat: 0, lon: 0) == nil)            // "no location" in many cameras
        #expect(g.place(lat: -48.0, lon: -140.0) == nil)    // mid-Pacific: nothing nearby
        _ = g.place(lat: 89.9, lon: 10)                     // poles don't crash
        // a city beats its own (slightly closer) districts; a separate town nearby keeps its name
        #expect(g.place(lat: 48.8566, lon: 2.3522)?.name == "Paris")
        #expect(g.place(lat: 47.4597, lon: 18.9550)?.name == "Budaörs")
    }

    @Test func scanPlacesPhotosAndCatalogCarriesThem() throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a.jpg"), dateTimeOriginal: "2020:01:01 10:00:00", gps: (48.8566, 2.3522))
        Fixtures.writeJPEG(to: root.appendingPathComponent("b.jpg"), dateTimeOriginal: "2020:01:02 10:00:00", color: (1, 0, 0))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        let snap = try CatalogService(db: db, settings: settings).catalog()
        let paris = try #require(snap.assets.first { $0.loc != nil })
        #expect(paris.loc == [48.8566, 2.3522])
        let place = try #require(snap.places.first { $0.id == paris.pl })
        #expect(place.name == "Paris" && place.cc == "FR")
        #expect(snap.places.count == 1)
        #expect(try AlbumService(db: db, settings: settings).search("paris") == [paris.id])
        #expect(try AlbumService(db: db, settings: settings).search("france") == [paris.id])
    }
}

@Suite struct FacesTests {
    struct Env { let db: AppDatabase; let faces: FaceService; let ids: [String]; let catalog: CatalogService }

    func env(photos: Int = 8) throws -> Env {
        let root = Fixtures.tempDir()
        for i in 0..<photos {
            Fixtures.writeJPEG(to: root.appendingPathComponent("p\(i).jpg"), width: 64, height: 48,
                               dateTimeOriginal: String(format: "2020:01:%02d 10:00:00", i + 1), color: (Double(i) / 10, 0.2, 0.3))
        }
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        let catalog = CatalogService(db: db, settings: settings)
        return Env(db: db, faces: FaceService(db: db), ids: try catalog.catalog().assets.map(\.id), catalog: catalog)
    }

    /// Unit vector near `base` (people are distinct axes; small noise on another axis).
    func face(_ base: Int, noise: Float = 0.2, seed: Int = 0) -> DetectedFace {
        var v = [Float](repeating: 0, count: 512)
        v[base] = 1
        v[100 + (seed % 50)] = noise
        return DetectedFace(x: 0.1, y: 0.1, w: 0.2, h: 0.2, quality: 0.8, embedding: FaceService.normalized(v))
    }

    func personOf(_ e: Env, asset: String) throws -> Int64? { try e.faces.faces(assetId: asset).first?.personId }

    @Test func clustersNamesAndAutoAssignsNewFaces() throws {
        let e = try env()
        #expect(try e.faces.pendingAssets().count == 8)
        // person A in photos 0-3, person B in 4-5, a stranger once in 6
        for i in 0..<4 { try e.faces.store(assetId: e.ids[i], faces: [face(0, seed: i)]) }
        for i in 4..<6 { try e.faces.store(assetId: e.ids[i], faces: [face(1, seed: i)]) }
        try e.faces.store(assetId: e.ids[6], faces: [face(2)])
        #expect(try e.faces.pendingAssets() == [e.ids[7]])
        #expect(try e.faces.cluster() == 1) // only A has enough faces for a group
        let people = try e.faces.people()
        #expect(people.count == 1 && people[0].count == 4 && people[0].name == nil)
        let a = people[0].id
        try e.faces.update(personId: a, name: "Anna", hidden: nil, coverFaceId: nil)
        // a new photo of A joins Anna on its own
        try e.faces.store(assetId: e.ids[7], faces: [face(0, seed: 9)])
        #expect(try personOf(e, asset: e.ids[7]) == a)
        // catalog + search carry the person
        let snap = try e.catalog.catalog()
        #expect(snap.people.first?.name == "Anna" && snap.assets.first { $0.id == e.ids[7] }?.pp == [a])
    }

    @Test func removedFaceIsNeverPutBack() throws {
        let e = try env()
        for i in 0..<5 { try e.faces.store(assetId: e.ids[i], faces: [face(0, seed: i)]) }
        try e.faces.cluster()
        let a = try #require(e.faces.people().first?.id)
        let wrong = try #require(e.faces.faces(assetId: e.ids[0]).first)
        try e.faces.assign(faceId: wrong.id, to: nil)
        try e.faces.cluster()
        try e.faces.cluster()
        #expect(try e.faces.face(id: wrong.id)?.personId != a)
        #expect(try e.faces.faces(personId: a).count == 4)
    }

    @Test func wrongMatchOfNamedPersonIsTakenAwayWhenRegrouping() throws {
        let e = try env()
        for i in 0..<5 { try e.faces.store(assetId: e.ids[i], faces: [face(0, seed: i)]) }
        try e.faces.cluster()
        let a = try #require(e.faces.people().first?.id)
        try e.faces.update(personId: a, name: "Anna", hidden: nil, coverFaceId: nil)
        // an old wrong automatic match (as left by a looser grouping): someone else entirely
        try e.faces.store(assetId: e.ids[5], faces: [face(1)])
        let stranger = try #require(e.faces.faces(assetId: e.ids[5]).first)
        #expect(stranger.personId == nil) // not matched now
        try e.db.writer.write { try $0.execute(sql: "UPDATE face SET personId = ?, assignment = 'auto' WHERE id = ?", arguments: [a, stranger.id]) }
        try e.faces.cluster()
        #expect(try e.faces.face(id: stranger.id)?.personId == nil)
        #expect(try e.faces.faces(personId: a).count == 5)
    }

    @Test func mergeAndHide() throws {
        let e = try env()
        for i in 0..<3 { try e.faces.store(assetId: e.ids[i], faces: [face(0, seed: i)]) }
        for i in 3..<6 { try e.faces.store(assetId: e.ids[i], faces: [face(1, seed: i)]) }
        try e.faces.cluster()
        let people = try e.faces.people()
        #expect(people.count == 2)
        try e.faces.update(personId: people[0].id, name: "Same", hidden: nil, coverFaceId: nil)
        try e.faces.merge(sources: [people[1].id], into: people[0].id)
        let merged = try e.faces.people()
        #expect(merged.count == 1 && merged[0].count == 6 && merged[0].name == "Same")
        // merging into a named person confirmed the faces: re-clustering keeps them
        try e.faces.cluster()
        #expect(try e.faces.people().first?.count == 6)
        try e.faces.update(personId: merged[0].id, name: nil, hidden: true, coverFaceId: nil)
        #expect(try e.catalog.catalog().assets.allSatisfy { $0.pp == nil })
    }

    @Test func createPersonFromFace() throws {
        let e = try env()
        try e.faces.store(assetId: e.ids[0], faces: [face(3)])
        let f = try #require(e.faces.faces(assetId: e.ids[0]).first)
        let id = try e.faces.createPerson(name: "Bob", faceIds: [f.id])
        #expect(try e.faces.people().first { $0.id == id }?.name == "Bob")
        try e.faces.cluster()
        #expect(try e.faces.face(id: f.id)?.personId == id)
    }
}
