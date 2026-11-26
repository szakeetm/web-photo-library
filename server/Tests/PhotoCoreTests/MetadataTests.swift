import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct MetadataServiceTests {
    let iso = ISO8601DateFormatter()

    func setup() throws -> (AppDatabase, LibraryScanner, URL, String) {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("a.jpg"), dateTimeOriginal: "2021:07:04 15:30:00", offset: "+02:00")
        let db = try AppDatabase.inMemory()
        let s = LibraryScanner(db: db, root: root, serverTZ: TimeZone(identifier: "UTC")!) { try FileHasher.sha256(url: $0) }
        _ = try s.detectChanges(progress: { _, _ in }, isCancelled: { false })
        let id = try db.writer.read { try String.fetchOne($0, sql: "SELECT id FROM asset")! }
        return (db, s, root, id)
    }

    func asset(_ db: AppDatabase, _ id: String) throws -> Asset { try db.writer.read { try Asset.fetchOne($0, key: id)! } }

    @Test func shiftSurvivesReindexAndReverts() throws {
        let (db, s, _, id) = try setup()
        let meta = MetadataService(db: db)
        try meta.change(ids: [id], DateChange(shift: 3600))
        var a = try asset(db, id)
        #expect(a.takenAt == iso.date(from: "2021-07-04T14:30:00Z") && a.dateSource == "user" && a.tzOffset == 7200)
        #expect(a.fileTakenAt == iso.date(from: "2021-07-04T13:30:00Z"))

        _ = try s.reindex(progress: { _, _ in }, isCancelled: { false })
        a = try asset(db, id)
        #expect(a.takenAt == iso.date(from: "2021-07-04T14:30:00Z") && a.dateSource == "user")
        #expect(try CatalogService(db: db, settings: SettingsStore(db: db)).catalogAsset(id: id)?.md == true)

        try meta.revert(ids: [id])
        a = try asset(db, id)
        #expect(a.takenAt == iso.date(from: "2021-07-04T13:30:00Z") && a.dateSource == "exif")
        #expect(try CatalogService(db: db, settings: SettingsStore(db: db)).catalogAsset(id: id)?.md == nil)
    }

    @Test func timeZoneKeepsWallClockOrInstant() throws {
        let (db, _, _, id) = try setup()
        let meta = MetadataService(db: db)
        // 15:30 at +02:00 → 15:30 at -05:00 (instant moves 7 h later)
        try meta.change(ids: [id], DateChange(tzOffset: -5 * 3600, keepWallClock: true))
        #expect(try asset(db, id).takenAt == iso.date(from: "2021-07-04T20:30:00Z"))
        try meta.revert(ids: [id])
        // same instant, shown as 08:30 at -05:00
        try meta.change(ids: [id], DateChange(tzOffset: -5 * 3600, keepWallClock: false))
        let a = try asset(db, id)
        #expect(a.takenAt == iso.date(from: "2021-07-04T13:30:00Z") && a.tzOffset == -5 * 3600)
    }

    @Test func shiftingBackToTheFileDateDropsTheOverride() throws {
        let (db, _, _, id) = try setup()
        let meta = MetadataService(db: db)
        try meta.change(ids: [id], DateChange(shift: 60))
        try meta.change(ids: [id], DateChange(shift: -60))
        #expect(try meta.override(id: id) == nil)
        #expect(try asset(db, id).dateSource == "exif")
    }

    @Test func changedContentKeepsTheDate() throws {
        let (db, s, root, id) = try setup()
        try MetadataService(db: db).change(ids: [id], DateChange(shift: -86400))
        Fixtures.writeJPEG(to: root.appendingPathComponent("a.jpg"), dateTimeOriginal: "2021:07:04 15:30:00", offset: "+02:00",
                           color: (1, 0, 0))
        // a different mtime so the scan sees the change
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: root.appendingPathComponent("a.jpg").path)
        _ = try s.detectChanges(progress: { _, _ in }, isCancelled: { false })
        let newId = try db.writer.read { try String.fetchOne($0, sql: "SELECT assetId FROM file")! }
        #expect(newId != id)
        let a = try asset(db, newId)
        #expect(a.takenAt == iso.date(from: "2021-07-03T13:30:00Z") && a.dateSource == "user")
    }

    @Test func rejectsAbsurdChanges() throws {
        let (db, _, _, id) = try setup()
        #expect(throws: MetadataError.self) { try MetadataService(db: db).change(ids: [id], DateChange(shift: .infinity)) }
        #expect(throws: MetadataError.self) { try MetadataService(db: db).change(ids: [id], DateChange(tzOffset: 20 * 3600)) }
    }
}

@Suite struct DateChangeDecodingTests {
    @Test func decodesWireFormat() throws {
        let c = try JSONDecoder().decode(DateChange.self, from: Data(#"{"setTo":"2020-01-02T03:04:05Z","tzOffset":3600}"#.utf8))
        #expect(c.shift == 0 && c.setTo == ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z") && c.tzOffset == 3600 && !c.keepWallClock)
    }
}
