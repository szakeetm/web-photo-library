import Foundation
import GRDB
import Testing
@testable import PhotoCore

/// An Apple Photos library as a source, with a small library made like Photos makes them.
@Suite struct PhotosLibraryTests {
    struct Env {
        let db: AppDatabase
        let settings: SettingsStore
        let library: URL
        let source: PhotosLibrarySource
        func scan() throws -> (ScanReport, [String]) {
            try PhotosLibraries.scan(source, db: db, settings: settings, serverTZ: TimeZone(identifier: "UTC")!,
                                     progress: { _, _ in }, isCancelled: { false })
        }
    }

    /// Photos.sqlite with the tables and columns read (Photos' own has many more).
    static func makeDatabase(_ url: URL, assets: [(pk: Int, uuid: String, dir: String, file: String, original: String, trashed: Bool, hidden: Bool, shared: Bool)],
                             albums: [(pk: Int, uuid: String, title: String, kind: Int, members: [Int])], edited: Set<String> = [],
                             dates: [Int: Date] = [:], places: [Int: (lat: Double, lon: Double)] = [:],
                             zones: [Int: (offset: Int, name: String)] = [:]) throws {
        let q = try DatabaseQueue(path: url.path)
        try q.write { d in
            try d.execute(sql: """
                CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZDIRECTORY TEXT, ZFILENAME TEXT, ZDATECREATED REAL,
                                     ZTRASHEDSTATE INTEGER, ZHIDDEN INTEGER, ZVISIBILITYSTATE INTEGER, ZKIND INTEGER, ZADJUSTMENTSSTATE INTEGER,
                                     ZLATITUDE REAL, ZLONGITUDE REAL);
                CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZORIGINALFILENAME TEXT,
                                                         ZTIMEZONEOFFSET INTEGER, ZTIMEZONENAME TEXT);
                CREATE TABLE ZGENERICALBUM (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZTITLE TEXT, ZKIND INTEGER, ZTRASHEDSTATE INTEGER);
                CREATE TABLE Z_3MEMORIESBEINGCURATEDASSETS (Z_3ASSETS INTEGER, Z_41MEMORIES INTEGER);
                CREATE TABLE Z_34ASSETS (Z_34ALBUMS INTEGER, Z_3ASSETS INTEGER, Z_FOK_3ASSETS INTEGER);
                """)
            for a in assets {
                // no place: -180, as Photos writes it
                try d.execute(sql: "INSERT INTO ZASSET VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)",
                              arguments: [a.pk, a.uuid, a.dir, a.file, dates[a.pk]?.timeIntervalSinceReferenceDate ?? Double(a.pk),
                                          a.trashed ? 1 : 0, a.hidden ? 1 : 0, a.shared ? 2 : 0, edited.contains(a.uuid) ? 2 : 0,
                                          places[a.pk]?.lat ?? -180, places[a.pk]?.lon ?? -180])
                try d.execute(sql: "INSERT INTO ZADDITIONALASSETATTRIBUTES (ZASSET, ZORIGINALFILENAME, ZTIMEZONEOFFSET, ZTIMEZONENAME) VALUES (?, ?, ?, ?)",
                              arguments: [a.pk, a.original, zones[a.pk]?.offset, zones[a.pk]?.name])
            }
            for al in albums {
                try d.execute(sql: "INSERT INTO ZGENERICALBUM VALUES (?, ?, ?, ?, 0)", arguments: [al.pk, al.uuid, al.title, al.kind])
                for m in al.members { try d.execute(sql: "INSERT INTO Z_34ASSETS VALUES (?, ?, 0)", arguments: [al.pk, m]) }
            }
        }
        try q.close()
    }

    /// The moment each test photo's EXIF says (10:00 at +09:00 on its day).
    static func exifDate(_ day: String) -> Date { ISO8601DateFormatter().date(from: "\(day)T01:00:00Z")! }

    func env(dates: [Int: Date]? = nil, places: [Int: (lat: Double, lon: Double)] = [:],
             zones: [Int: (offset: Int, name: String)] = [:]) throws -> Env {
        let library = Fixtures.tempDir().appendingPathComponent("My Photos.photoslibrary", isDirectory: true)
        let o = library.appendingPathComponent("originals")
        Fixtures.writeJPEG(to: o.appendingPathComponent("A/AAAA-1.jpeg"), dateTimeOriginal: "2024:03:30 10:00:00", offset: "+09:00", color: (1, 0, 0))
        Fixtures.writeJPEG(to: o.appendingPathComponent("B/BBBB-2.jpeg"), dateTimeOriginal: "2024:03:31 10:00:00", offset: "+09:00", color: (0, 1, 0))
        Fixtures.writeJPEG(to: o.appendingPathComponent("C/CCCC-3.jpeg"), dateTimeOriginal: "2024:04:01 10:00:00", offset: "+09:00", color: (0, 0, 1))
        Fixtures.writeJPEG(to: o.appendingPathComponent("D/DDDD-4.jpeg"), dateTimeOriginal: "2024:04:02 10:00:00", offset: "+09:00", color: (1, 1, 0))
        try FileManager.default.createDirectory(at: library.appendingPathComponent("database"), withIntermediateDirectories: true)
        try Self.makeDatabase(library.appendingPathComponent("database/Photos.sqlite"), assets: [
            (1, "AAAA-1", "A", "AAAA-1.jpeg", "IMG_0001.JPG", false, false, false),
            (2, "BBBB-2", "B", "BBBB-2.jpeg", "IMG_0002.JPG", false, false, false),
            (3, "CCCC-3", "C", "CCCC-3.jpeg", "IMG_0003.JPG", true, false, false),    // deleted in Photos
            (4, "DDDD-4", "D", "DDDD-4.jpeg", "IMG_0004.JPG", false, true, false),    // hidden in Photos
            (5, "EEEE-5", "E", "EEEE-5.jpeg", "IMG_0005.JPG", false, false, true),    // from a shared album (no original)
        ], albums: [
            (10, "ALB-1", "Japan", 2, [2, 1, 3]),
            (11, "FOLDER-1", "Trips", 4000, [1]),   // a folder of albums, not an album
        ], dates: dates ?? [1: Self.exifDate("2024-03-30"), 2: Self.exifDate("2024-03-31"),
                            3: Self.exifDate("2024-04-01"), 4: Self.exifDate("2024-04-02")],
           places: places, zones: zones)
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        let source = try PhotosLibraries.add(path: library.path, settings)
        return Env(db: db, settings: settings, library: library, source: source)
    }

    @Test func indexesOwnPhotosWithTheirNamesAndAlbums() throws {
        let e = try env()
        #expect(e.source.title == "My Photos")
        let (r, _) = try e.scan()
        #expect(r.added == 2, "\(r)")
        let rows = try e.db.writer.read { try FileRow.filter(Column("root") == e.source.root).order(Column("relPath")).fetchAll($0) }
        #expect(rows.map(\.relPath) == ["originals/A/AAAA-1.jpeg", "originals/B/BBBB-2.jpeg"])
        #expect(rows.map(\.name) == ["IMG_0001.JPG", "IMG_0002.JPG"])
        let catalog = CatalogService(db: e.db, settings: e.settings)
        #expect(try catalog.originalName(id: rows[0].assetId) == "IMG_0001.JPG")
        // read in place
        #expect(try catalog.originals.original(id: rows[0].assetId)?.path == e.library.appendingPathComponent("originals/A/AAAA-1.jpeg").path)
        #expect(try catalog.originalName(id: rows[1].assetId) == "IMG_0002.JPG")
        // the album, oldest first; folders of albums aren't albums
        let albums = try AlbumService(db: e.db, settings: e.settings)
        let album = try #require(try e.db.writer.read { try Row.fetchOne($0, sql: "SELECT id, title FROM album WHERE source = 'photos'") })
        #expect(album["title"] as String == "Japan")
        #expect(try albums.members(id: album["id"]) == [rows[0].assetId, rows[1].assetId])
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM album") } == 1)
        // the top folder carries the library's name; stats
        #expect(try e.db.writer.read { try String.fetchOne($0, sql: "SELECT name FROM folder WHERE root = ? AND relPath = ''", arguments: [e.source.root]) } == "My Photos")
        let stats = try #require(try e.settings.get(.photosLibraryStats).first)
        #expect(stats.items == 2 && stats.onDisk == 2 && stats.albums == 1)

        // again: nothing new, the album isn't duplicated
        let (again, _) = try e.scan()
        #expect(again.unchanged == 2 && again.added == 0)
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM album") } == 1)
    }

    /// Rewrites the test library's database with `edited` assets marked as edited in Photos.
    func markEdited(_ e: Env, _ edited: Set<String>) throws {
        let url = e.library.appendingPathComponent("database/Photos.sqlite")
        let q = try DatabaseQueue(path: url.path)
        try q.write { d in
            try d.execute(sql: "UPDATE ZASSET SET ZADJUSTMENTSSTATE = CASE WHEN ZUUID IN (SELECT value FROM json_each(?)) THEN 2 ELSE 0 END",
                          arguments: [String(decoding: try JSONEncoder().encode(Array(edited)), as: UTF8.self)])
        }
        try q.close()
    }

    @Test func anEditedPhotoIsItsRenderedVersionAndFollowsARevert() throws {
        let e = try env()
        // edited in Photos: its rendered version is next to the original
        let render = e.library.appendingPathComponent("resources/renders/B/BBBB-2_1_201_a.jpeg")
        Fixtures.writeJPEG(to: render, dateTimeOriginal: "2024:03:31 10:00:00", offset: "+09:00", color: (0, 0.5, 0))
        try markEdited(e, ["BBBB-2"])
        _ = try e.scan()
        let row = try #require(try e.db.writer.read { try FileRow.filter(Column("relPath").like("%BBBB-2%")).fetchOne($0) })
        #expect(row.relPath == "resources/renders/B/BBBB-2_1_201_a.jpeg")
        #expect(row.name == "IMG_0002.jpeg")
        #expect(row.assetId == (try FileHasher.sha256(url: render)))
        let catalog = CatalogService(db: e.db, settings: e.settings)
        #expect(try catalog.originals.original(id: row.assetId)?.path == render.path)
        let album = try #require(try e.db.writer.read { try Int64.fetchOne($0, sql: "SELECT id FROM album WHERE source = 'photos'") })
        #expect(try AlbumService(db: e.db, settings: e.settings).members(id: album).contains(row.assetId))
        try e.db.writer.write { try $0.execute(sql: "UPDATE asset SET favorite = 1 WHERE id = ?", arguments: [row.assetId]) }

        // reverted in Photos: the original stands for it again, in the same album, still a favourite
        try FileManager.default.removeItem(at: render)
        try markEdited(e, [])
        let (r, _) = try e.scan()
        #expect(r.removed == 0, "\(r)")
        let back = try #require(try e.db.writer.read { try FileRow.filter(Column("relPath").like("%BBBB-2%")).fetchOne($0) })
        #expect(back.relPath == "originals/B/BBBB-2.jpeg" && back.name == "IMG_0002.JPG")
        #expect(back.assetId != row.assetId)
        #expect(try AlbumService(db: e.db, settings: e.settings).members(id: album).contains(back.assetId))
        #expect(try e.db.writer.read { try Bool.fetchOne($0, sql: "SELECT favorite FROM asset WHERE id = ?", arguments: [back.assetId]) } == true)
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM asset WHERE missingSince IS NULL") } == 2)
    }

    @Test func theSamePhotoInTheLibraryFolderIsOnePhoto() throws {
        let e = try env()
        let folder = Fixtures.tempDir()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("2024"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: e.library.appendingPathComponent("originals/A/AAAA-1.jpeg"), to: folder.appendingPathComponent("2024/IMG_0001.JPG"))
        try e.settings.set(.libraryPath, folder.path)
        _ = try LibraryScanner(db: e.db, root: folder, serverTZ: TimeZone(identifier: "UTC")!).detectChanges(progress: { _, _ in }, isCancelled: { false })
        _ = try e.scan()
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM asset") } == 2)
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM file") } == 3)
    }

    @Test func originalsOnlyInICloudAreCounted() throws {
        let e = try env()
        try FileManager.default.removeItem(at: e.library.appendingPathComponent("originals/B/BBBB-2.jpeg"))
        let (r, notes) = try e.scan()
        #expect(r.added == 1)
        #expect(notes.contains { $0.contains("1 of 2 photos have no original in the library") }, "\(notes)")
    }

    @Test func removingTheLibraryForgetsItsFilesButKeepsAlbums() throws {
        let e = try env()
        _ = try e.scan()
        try PhotosLibraries.remove(id: e.source.id, db: e.db, e.settings)
        #expect(try PhotosLibraries.all(e.settings).isEmpty)
        #expect(try e.db.writer.read { try FileRow.fetchCount($0) } == 0)
        #expect(try e.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM album") } == 1)
    }

    @Test func refusesWhatIsntALibrary() throws {
        let settings = SettingsStore(db: try AppDatabase.inMemory())
        #expect(throws: PhotosLibraryError.self) { try PhotosLibraries.add(path: Fixtures.tempDir().path, settings) }
        #expect(PhotosLibraryReader.uuid(of: "9/9cd3-aa_3.mov") == "9CD3-AA")
    }

    @Test func datesAndPlacesAreAsPhotosShowsThem() async throws {
        // A: Photos has the file's own date. B: adjusted in Photos (or a photo whose file has no date, like
        // one saved from WhatsApp), with its zone and a place the file doesn't have.
        let adjusted = ISO8601DateFormatter().date(from: "2024-04-05T12:00:00Z")!
        // A: Photos keeps a date a few seconds before the camera's: the camera's stays
        let e = try env(dates: [1: Self.exifDate("2024-03-30").addingTimeInterval(-6), 2: adjusted],
                        places: [2: (35.6861, 139.7118)], zones: [2: (7200, "GMT+0200")])
        _ = try e.scan()
        func asset(_ uuid: String) throws -> Asset {
            try e.db.writer.read { d in
                let row = try #require(try FileRow.filter(Column("relPath").like("%\(uuid)%")).fetchOne(d))
                return try #require(try Asset.fetchOne(d, key: row.assetId))
            }
        }
        let a = try asset("AAAA-1")
        #expect(a.takenAt == Self.exifDate("2024-03-30") && a.tzOffset == 9 * 3600 && a.dateSource == "exif")
        #expect(a.lat == nil && a.locationSource == nil)
        var b = try asset("BBBB-2")
        #expect(b.takenAt == adjusted && b.tzOffset == 7200 && b.dateSource == "photos" && b.fileTakenAt == adjusted)
        #expect(b.lat == 35.6861 && b.lon == 139.7118 && b.locationSource == "photos")

        // B's date is written into its exported copy; the catalog tells the web so
        let catalog = CatalogService(db: e.db, settings: e.settings)
        #expect(b.writesDateOnExport && !a.writesDateOnExport)
        #expect(try catalog.catalog().assets.first { $0.id == b.id }?.pd == true)
        #expect(try catalog.catalog().assets.first { $0.id == a.id }?.pd == nil)
        let cache = Fixtures.tempDir()
        let ex = ExportService(db: e.db, catalog: catalog, edits: EditService(db: e.db, catalog: catalog, derivatives: { DerivativeStore(cacheDir: cache) }),
                               ffmpeg: nil, cacheDir: cache)
        let f = try #require(try await ex.editedFile(id: b.id, format: .jpeg))
        #expect(try #require(ImageProbe.probe(url: f.url)).exifDate == adjusted)
        #expect(try await ex.editedFile(id: a.id, format: .jpeg) == nil)

        // nothing changes on the next scan
        let (again, _) = try e.scan()
        #expect(again.updated == 0 && again.unchanged == 2, "\(again)")

        // a date set here stays the user's
        let mine = ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z")!
        let bid = b.id
        try await e.db.writer.write { d in
            try d.execute(sql: "INSERT INTO meta_edit (assetId, takenAt, tzOffset, createdAt) VALUES (?, ?, 0, ?)", arguments: [bid, mine, Date()])
            try d.execute(sql: "UPDATE asset SET takenAt = ?, tzOffset = 0, dateSource = 'user' WHERE id = ?", arguments: [mine, bid])
        }
        _ = try e.scan()
        b = try asset("BBBB-2")
        #expect(b.takenAt == mine && b.dateSource == "user" && b.fileTakenAt == adjusted)
    }

    /// An earlier version took Photos' date even when it was seconds from the camera's: read once again.
    @Test func datesTakenFromPhotosBeforeAreReadAgainOnce() throws {
        let e = try env(dates: [1: Self.exifDate("2024-03-30").addingTimeInterval(-6), 2: Self.exifDate("2024-03-31")])
        _ = try e.scan()
        let photosDate = Self.exifDate("2024-03-30").addingTimeInterval(-6)
        try e.db.writer.write { d in
            try d.execute(sql: """
                UPDATE asset SET takenAt = ?, fileTakenAt = ?, dateSource = 'photos', fileDateSource = 'photos'
                WHERE id = (SELECT assetId FROM file WHERE relPath LIKE '%AAAA-1%')
                """, arguments: [photosDate, photosDate])
        }
        try e.settings.set(.photosDatesReread, [])
        _ = try e.scan()
        let a = try e.db.writer.read { d in
            try #require(try Asset.fetchOne(d, sql: "SELECT * FROM asset WHERE id = (SELECT assetId FROM file WHERE relPath LIKE '%AAAA-1%')"))
        }
        #expect(a.takenAt == Self.exifDate("2024-03-30") && a.dateSource == "exif")
        #expect(try e.settings.get(.photosDatesReread) == [e.source.root])
    }
}
