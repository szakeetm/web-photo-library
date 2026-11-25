import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct MetadataResolverTests {
    let utc = TimeZone(identifier: "UTC")!
    let budapest = TimeZone(identifier: "Europe/Budapest")!
    let iso = ISO8601DateFormatter()

    func probe(local: DateComponents? = nil, offset: Int? = nil, lat: Double? = nil, lon: Double? = nil) -> ProbeResult {
        var abs: Date?
        if let local, let offset {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: offset)!
            abs = cal.date(from: local)
        }
        return ProbeResult(width: 1, height: 1, mime: "public.jpeg", exifDate: abs, exifLocalDate: local, exifOffset: offset,
                           lat: lat, lon: lon, make: nil, model: nil, lens: nil, iso: nil, aperture: nil, shutter: nil,
                           focal: nil, orientation: 1)
    }
    let local = DateComponents(year: 2021, month: 7, day: 4, hour: 15, minute: 30, second: 0)

    @Test func sidecarBeatsExif() {
        let side = SidecarData(takenAt: iso.date(from: "2020-01-01T10:00:00Z"), lat: 1, lon: 2, description: "d", favorited: true)
        let r = MetadataResolver.resolve(probe: probe(local: local, offset: 7200, lat: 5, lon: 6), sidecar: side,
                                         fileMTime: Date(), serverTZ: utc)
        #expect(r.takenAt == iso.date(from: "2020-01-01T10:00:00Z"))
        #expect(r.dateSource == "sidecar" && r.tzOffset == 7200)
        #expect(r.lat == 1 && r.lon == 2 && r.locationSource == "sidecar")
        #expect(r.description == "d" && r.favorited == true)
    }

    @Test func exifWithOffset() {
        let r = MetadataResolver.resolve(probe: probe(local: local, offset: 7200, lat: 5, lon: 6), sidecar: nil, fileMTime: Date(), serverTZ: utc)
        #expect(r.takenAt == iso.date(from: "2021-07-04T13:30:00Z") && r.tzOffset == 7200 && r.dateSource == "exif")
        #expect(r.lat == 5 && r.locationSource == "exif")
    }

    @Test func floatingExifUsesServerTZ() {
        let r = MetadataResolver.resolve(probe: probe(local: local), sidecar: nil, fileMTime: Date(), serverTZ: budapest)
        #expect(r.takenAt == iso.date(from: "2021-07-04T13:30:00Z") && r.tzOffset == 7200)
    }

    @Test func sidecarInstantPlusExifLocalDerivesOffset() {
        let side = SidecarData(takenAt: iso.date(from: "2021-07-04T22:30:00Z"))
        let r = MetadataResolver.resolve(probe: probe(local: local), sidecar: side, fileMTime: Date(), serverTZ: utc)
        #expect(r.tzOffset == -7 * 3600)
    }

    @Test func fileDateFallback() {
        let m = iso.date(from: "2019-05-05T05:05:05Z")!
        let r = MetadataResolver.resolve(probe: probe(), sidecar: nil, fileMTime: m, serverTZ: budapest)
        #expect(r.takenAt == m && r.dateSource == "file" && r.tzOffset == 7200 && r.lat == nil)
    }
}

@Suite struct LibraryScannerTests {
    final class Counter: @unchecked Sendable { var n = 0 }

    func make(_ root: URL, counter: Counter = Counter()) throws -> (AppDatabase, LibraryScanner) {
        let db = try AppDatabase.inMemory()
        let s = LibraryScanner(db: db, root: root, serverTZ: TimeZone(identifier: "UTC")!) { url in
            counter.n += 1
            return try FileHasher.sha256(url: url)
        }
        return (db, s)
    }
    func scan(_ s: LibraryScanner) throws -> ScanReport { try s.detectChanges(progress: { _, _ in }, isCancelled: { false }) }

    func threeImages() -> URL {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a.jpg"), color: (1, 0, 0))
        Fixtures.writeJPEG(to: root.appendingPathComponent("A/b.jpg"), color: (0, 1, 0))
        Fixtures.writeJPEG(to: root.appendingPathComponent("B/c.jpg"), color: (0, 0, 1))
        try! Data("{}".utf8).write(to: root.appendingPathComponent("A/b.jpg.json"))
        try! Data().write(to: root.appendingPathComponent("B/notes.txt"))  // non-media: ignored
        return root
    }

    @Test func firstScanAdds() throws {
        let (db, s) = try make(threeImages())
        let r = try scan(s)
        #expect(r.added == 3 && r.skipped == 0)
        #expect(try db.writer.read { try Folder.fetchCount($0) } == 3)
        #expect(try db.writer.read { try FileRow.fetchOne($0, sql: "SELECT * FROM file WHERE relPath = 'A/b.jpg'")?.sidecarRelPath } == "A/b.jpg.json")
    }

    @Test func duplicateContentOneAsset() throws {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("A/x.jpg"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("A/x.jpg"), to: root.appendingPathComponent("B/x.jpg"))
        let (db, s) = try make(root)
        _ = try scan(s)
        #expect(try db.writer.read { try Asset.fetchCount($0) } == 1)
        #expect(try db.writer.read { try FileRow.fetchCount($0) } == 2)
    }

    @Test func secondScanNoRehash() throws {
        let c = Counter()
        let (_, s) = try make(threeImages(), counter: c)
        _ = try scan(s)
        let r = try scan(s)
        #expect(c.n == 3)
        #expect(r.unchanged == 3 && r.added == 0 && r.updated == 0 && r.removed == 0)
    }

    @Test func deletedFileMarksMissing() throws {
        let root = threeImages()
        let (db, s) = try make(root)
        _ = try scan(s)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.jpg"))
        let r = try scan(s)
        #expect(r.removed == 1)
        #expect(try db.writer.read { try Asset.filter(Column("missingSince") != nil).fetchCount($0) } == 1)
        #expect(try db.writer.read { try Asset.fetchCount($0) } == 3)
    }

    @Test func contentChangedRelinksFavorite() throws {
        let root = threeImages()
        let (db, s) = try make(root)
        _ = try scan(s)
        let path = root.appendingPathComponent("a.jpg")
        let oldId = try FileHasher.sha256(url: path)
        try db.writer.write { try $0.execute(sql: "UPDATE asset SET favorite = 1, favoriteUserSet = 1, description = 'keep' WHERE id = ?", arguments: [oldId]) }
        Fixtures.writeJPEG(to: path, color: (0.5, 0.5, 0.5))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: path.path)
        let r = try scan(s)
        #expect(r.updated == 1)
        let newId = try FileHasher.sha256(url: path)
        let a = try #require(try db.writer.read { try Asset.fetchOne($0, key: newId) })
        #expect(a.favorite && a.favoriteUserSet && a.description == "keep")
    }

    @Test func corruptFileSkipped() throws {
        let root = threeImages()
        try Data("garbage".utf8).write(to: root.appendingPathComponent("bad.jpg"))
        try Data().write(to: root.appendingPathComponent("empty.heic"))
        let (_, s) = try make(root)
        let r = try scan(s)
        #expect(r.added == 3 && r.skipped == 2 && r.errors.count == 2)
    }

    @Test func unreadableRootThrows() throws {
        let (_, s) = try make(URL(fileURLWithPath: "/nonexistent-\(UUID())"))
        #expect(throws: ScanError.self) { try scan(s) }
    }

    @Test func unicodeNamesRoundTrip() throws {
        let root = Fixtures.tempDir()
        let name = "Árvíztűrő tükörfúrógép 1.jpg"
        Fixtures.writeJPEG(to: root.appendingPathComponent("Nyár 2021/\(name)"))
        try Data(#"{"favorited":true}"#.utf8).write(to: root.appendingPathComponent("Nyár 2021/\(name.precomposedStringWithCanonicalMapping).json"))
        let (db, s) = try make(root)
        _ = try scan(s)
        let f = try #require(try db.writer.read { try FileRow.fetchOne($0) })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(f.relPath).path))
        #expect(try db.writer.read { try Asset.fetchOne($0)?.favorite } == true)
    }

    @Test func libraryUntouched() throws {
        let root = threeImages()
        func snapshot() -> [String] {
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])!
            return e.compactMap { $0 as? URL }.map { u in
                let v = try! u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return "\(u.path)|\(v.fileSize ?? -1)|\(v.contentModificationDate!.timeIntervalSince1970)"
            }.sorted()
        }
        let before = snapshot()
        let (_, s) = try make(root)
        _ = try scan(s)
        _ = try s.reindex(progress: { _, _ in }, isCancelled: { false })
        #expect(snapshot() == before)
    }

    @Test func reindexKeepsUserFavorite() throws {
        let root = threeImages()
        let (db, s) = try make(root)
        _ = try scan(s)
        try Data(#"{"favorited":false,"photoTakenTime":{"timestamp":"1000000000"}}"#.utf8).write(to: root.appendingPathComponent("A/b.jpg.json"))
        let id = try FileHasher.sha256(url: root.appendingPathComponent("A/b.jpg"))
        try db.writer.write { try $0.execute(sql: "UPDATE asset SET favorite = 1, favoriteUserSet = 1 WHERE id = ?", arguments: [id]) }
        _ = try s.reindex(progress: { _, _ in }, isCancelled: { false })
        let a = try #require(try db.writer.read { try Asset.fetchOne($0, key: id) })
        #expect(a.favorite && a.takenAt == Date(timeIntervalSince1970: 1_000_000_000))
    }

    @Test func unreadableSubfolderIsNotTreatedAsDeleted() throws {
        let root = threeImages()
        let (db, s) = try make(root)
        _ = try scan(s)
        let sub = root.appendingPathComponent("A").path
        chmod(sub, 0o000)
        defer { chmod(sub, 0o755) }
        let r = try scan(s)
        #expect(r.removed == 0)
        #expect(r.errors.contains { $0.contains("A") })
        #expect(try db.writer.read { try Asset.filter(Column("missingSince") != nil).fetchCount($0) } == 0)
    }

    @Test func excludedDirectoriesAreSkipped() throws {
        let root = threeImages()
        Fixtures.writeJPEG(to: root.appendingPathComponent("data/cache/thumb/ab/x.heic"))
        let db = try AppDatabase.inMemory()
        let s = LibraryScanner(db: db, root: root, serverTZ: TimeZone(identifier: "UTC")!,
                               excluding: [root.appendingPathComponent("data")])
        let r = try scan(s)
        #expect(r.added == 3)
    }
}
