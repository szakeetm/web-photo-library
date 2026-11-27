import Foundation
import GRDB
import CryptoKit

/// Compact per-asset record sent to clients (kept small: it is replicated to devices).
public struct CatalogAsset: Codable, Sendable, Equatable {
    public var id: String
    public var w: Int
    public var h: Int
    public var t: String        // capture instant, ISO-8601 UTC
    public var tz: Int?         // seconds east of UTC at capture
    public var fav: Bool
    public var bh: String?
    public var ev: Int
    public var folders: [Int64]
    public var name: String
    /// [lat, lon] when the photo has a location.
    public var loc: [Double]? = nil
    /// GeoNames place id (see `places`).
    public var pl: Int64? = nil
    /// People in the photo (person ids).
    public var pp: [Int64]? = nil
    /// Duration in seconds, rounded to 0.1 (videos only).
    public var dur: Double? = nil
    /// True when the photo is a Live Photo (has a motion clip).
    public var live: Bool? = nil
    /// True when the user changed the date (kept in the database only, applied on export).
    public var md: Bool? = nil
    /// True when the date is Apple Photos' and the file has another one or none (applied on export, like `md`).
    public var pd: Bool? = nil
    /// MediaFlags (1 screenshot, 2 selfie, 4 portrait); absent when 0.
    public var mf: Int? = nil
    /// Date added (seconds since 1970).
    public var ad: Int? = nil
    /// Video trim [start, end] in seconds (kept in the database, applied when playing and exporting).
    public var tr: [Double]? = nil
    /// True when archived (left out of the Library view); absent otherwise.
    public var arc: Bool? = nil
}

/// Version of the catalog payload. Clients keeping an offline replica discard it when this changes.
public let catalogFormat = 10

public struct CatalogSnapshot: Codable, Sendable {
    public var format = catalogFormat
    /// Random id of this database: a replica made from another database (e.g. after a reset) must be discarded.
    public var catalogId: String
    public var seq: Int64
    public var assets: [CatalogAsset]
    public var folders: [FolderNode]
    public var albums: [CatalogAlbum]
    public var people: [CatalogPerson]
    public var places: [CatalogPlace]
    public var hashes: ListHashes
}

/// Digests of the folder, people and place lists: a delta leaves out the lists the client already has.
public struct ListHashes: Codable, Sendable, Equatable {
    public var folders: String
    public var people: String
    public var places: String

    static func of<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let data = (try? enc.encode(value)) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `"<folders>,<people>,<places>"` as a client sends it back.
    public init?(query: String?) {
        let parts = (query ?? "").split(separator: ",").map(String.init)
        guard parts.count == 3 else { return nil }
        folders = parts[0]; people = parts[1]; places = parts[2]
    }

    init(folders: String, people: String, places: String) {
        self.folders = folders; self.people = people; self.places = places
    }
}

public struct FolderNode: Codable, Sendable, Equatable {
    public var id: Int64
    public var root: String
    public var parentId: Int64?
    public var name: String
    public var relPath: String
    public var count: Int
    public var coverId: String?
}

/// Changes since a sequence number: upserted and deleted assets and albums; the folder, people and
/// place lists only when they differ from what the client has (`hashes`). `reset` means the client
/// must download the full snapshot instead.
public struct CatalogDelta: Codable, Sendable {
    public var format = catalogFormat
    public var catalogId: String
    public var seq: Int64
    public var reset: Bool
    public var assets: [CatalogAsset]
    public var deleted: [String]
    public var folders: [FolderNode]?
    /// Albums created or changed since `since` (complete entries).
    public var albums: [CatalogAlbum]?
    public var deletedAlbums: [Int64]? = nil
    public var people: [CatalogPerson]?
    public var places: [CatalogPlace]?
    public var hashes: ListHashes? = nil
}

public struct AssetDetail: Codable, Sendable {
    public var asset: Asset
    public var files: [String]
    public var faces: [FaceInfo] = []
    public var place: CatalogPlace? = nil
    /// Text recognised in the photo.
    public var text: String? = nil
}

public final class CatalogService: Sendable {
    let db: AppDatabase
    let settings: SettingsStore
    /// Where originals are read from: every read of a photo's or video's bytes goes through it.
    public let originals: OriginalStore

    public init(db: AppDatabase, settings: SettingsStore, originals: OriginalStore? = nil) {
        self.db = db
        self.settings = settings
        self.originals = originals ?? OriginalStores.make(db: db, settings: settings)
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func catalogAssets(_ d: Database, id: String? = nil) throws -> [CatalogAsset] {
        try catalogAssets(d, ids: id.map { [$0] })
    }

    /// Present assets, all of them or only `ids`; with `trashed`, those in the Trash instead.
    static func catalogAssets(_ d: Database, ids: [String]?, trashed: Bool = false) throws -> [CatalogAsset] {
        var filter = ""
        var args: StatementArguments = []
        if let ids {
            filter = "AND a.id IN (SELECT value FROM json_each(?))"
            args = [String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)]
        }
        let rows = try Row.fetchAll(d, sql: """
            SELECT a.id, a.width, a.height, a.takenAt, a.tzOffset, a.favorite, a.archived, a.blurhash, a.editVersion, a.mediaFlags, a.addedAt,
                   a.lat, a.lon, a.placeId, a.kind, a.duration, a.dateSource = 'photos' AS pd,
                   EXISTS (SELECT 1 FROM motion m WHERE m.assetId = a.id) AS live,
                   EXISTS (SELECT 1 FROM meta_edit me WHERE me.assetId = a.id) AS md,
                   (SELECT vt.start || ',' || vt."end" FROM video_trim vt WHERE vt.assetId = a.id) AS trim,
                   (SELECT GROUP_CONCAT(DISTINCT fc.personId) FROM face fc JOIN person p ON p.id = fc.personId
                     WHERE fc.assetId = a.id AND p.hidden = 0) AS people,
                   GROUP_CONCAT(f.folderId) AS folders, MIN(COALESCE(f.name, f.relPath)) AS relPath
            FROM asset a JOIN file f ON f.assetId = a.id
            WHERE a.missingSince IS NULL AND \(trashed ? "" : "NOT ")EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id) \(filter)
            GROUP BY a.id
            ORDER BY a.takenAt DESC, a.id
            """, arguments: args)
        return rows.map { r -> CatalogAsset in
                let folders = ((r["folders"] as String?) ?? "").split(separator: ",").compactMap { Int64($0) }
                let rel: String = r["relPath"]
                let lat: Double? = r["lat"], lon: Double? = r["lon"]
                let round5 = { (v: Double) in (v * 1e5).rounded() / 1e5 }
                let people = ((r["people"] as String?) ?? "").split(separator: ",").compactMap { Int64($0) }.sorted()
                let duration: Double? = (r["kind"] as String) == "video" ? r["duration"] : nil
                return CatalogAsset(id: r["id"], w: r["width"], h: r["height"], t: Self.iso.string(from: r["takenAt"]),
                                    tz: r["tzOffset"], fav: r["favorite"], bh: r["blurhash"], ev: r["editVersion"],
                                    folders: Array(Set(folders)).sorted(), name: (rel as NSString).lastPathComponent,
                                    loc: (lat != nil && lon != nil && !(lat == 0 && lon == 0)) ? [round5(lat!), round5(lon!)] : nil,
                                    pl: r["placeId"], pp: people.isEmpty ? nil : people,
                                    dur: duration.map { ($0 * 10).rounded() / 10 }, live: (r["live"] as Bool) ? true : nil,
                                    md: (r["md"] as Bool) ? true : nil, pd: (r["pd"] as Bool) ? true : nil,
                                    mf: (r["mediaFlags"] as Int) == 0 ? nil : r["mediaFlags"],
                                    ad: (r["addedAt"] as Date?).map { Int($0.timeIntervalSince1970) },
                                    tr: (r["trim"] as String?).map { $0.split(separator: ",").compactMap { Double($0) }.map { ($0 * 100).rounded() / 100 } },
                                    arc: (r["archived"] as Bool) ? true : nil)
        }
    }

    /// The catalog entries for these (present) assets.
    public func catalogAssets(ids: [String]) throws -> [CatalogAsset] {
        try db.writer.read { try Self.catalogAssets($0, ids: ids) }
    }

    /// The catalog entry for one (present) asset.
    public func catalogAsset(id: String) throws -> CatalogAsset? {
        try db.writer.read { try Self.catalogAssets($0, id: id).first }
    }

    public func catalog() throws -> CatalogSnapshot {
        try db.writer.read { d in
            let assets = try Self.catalogAssets(d)
            let seq = try Self.currentSeq(d)
            let folders = try Self.folders(d), people = try FaceService.catalogPeople(d), places = try PlaceService.catalogPlaces(d)
            return CatalogSnapshot(catalogId: try Self.catalogId(d), seq: seq, assets: assets, folders: folders,
                                   albums: try AlbumService(db: db, settings: settings).catalogAlbums(d),
                                   people: people, places: places,
                                   hashes: ListHashes(folders: ListHashes.of(folders), people: ListHashes.of(people), places: ListHashes.of(places)))
        }
    }

    /// Keeps only the latest change of each item. Deltas only ask which items changed after a point,
    /// so they stay the same, while the log stays as long as the catalog instead of growing forever.
    @discardableResult
    public func compactChangeLog() throws -> Int {
        try db.writer.write { try ChangeLog.compact($0) }
    }

    static func currentSeq(_ d: Database) throws -> Int64 {
        try Int64.fetchOne(d, sql: "SELECT MAX(seq) FROM change_log") ?? 0
    }

    static func catalogId(_ d: Database) throws -> String {
        let raw = try String.fetchOne(d, sql: "SELECT value FROM setting WHERE key = 'catalogId'") ?? "\"\""
        return (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? ""
    }

    /// Everything that changed after `since` in the database identified by `catalogId`.
    public func changes(since: Int64, catalogId clientCatalog: String?, have: ListHashes? = nil) throws -> CatalogDelta {
        try db.writer.read { d in
            let id = try Self.catalogId(d)
            let seq = try Self.currentSeq(d)
            guard clientCatalog == id, since >= 0, since <= seq else {
                return CatalogDelta(catalogId: id, seq: seq, reset: true, assets: [], deleted: [])
            }
            guard since < seq else {
                return CatalogDelta(catalogId: id, seq: seq, reset: false, assets: [], deleted: [])
            }
            let rows = try Row.fetchAll(d, sql: "SELECT DISTINCT entity, entityId FROM change_log WHERE seq > ?", arguments: [since])
            let assetIds = Array(Set(rows.filter { $0["entity"] == "asset" }.map { $0["entityId"] as String }))
            let present = try Self.catalogAssets(d, ids: assetIds)
            let presentIds = Set(present.map(\.id))
            let albumRows = rows.filter { $0["entity"] == "album" }.map { $0["entityId"] as String }
            let albumIds = Set(albumRows.compactMap { Int64($0) })
            // "*" (older databases): every album may have changed
            let albums = albumRows.contains("*") ? try AlbumService(db: db, settings: settings).catalogAlbums(d)
                : albumIds.isEmpty ? [] : try AlbumService(db: db, settings: settings).catalogAlbums(d, ids: albumIds)
            let folders = try Self.folders(d), people = try FaceService.catalogPeople(d), places = try PlaceService.catalogPlaces(d)
            let hashes = ListHashes(folders: ListHashes.of(folders), people: ListHashes.of(people), places: ListHashes.of(places))
            return CatalogDelta(catalogId: id, seq: seq, reset: false, assets: present,
                                deleted: assetIds.filter { !presentIds.contains($0) }.sorted(),
                                folders: have?.folders == hashes.folders ? nil : folders,
                                albums: albums,
                                deletedAlbums: albumIds.subtracting(albums.map(\.id)).sorted(),
                                people: have?.people == hashes.people ? nil : people,
                                places: have?.places == hashes.places ? nil : places,
                                hashes: hashes)
        }
    }

    public func folderTree() throws -> [FolderNode] { try db.writer.read { try Self.folders($0) } }

    static func folders(_ d: Database) throws -> [FolderNode] {
        let rows = try Row.fetchAll(d, sql: """
            SELECT fo.id, fo.root, fo.parentId, fo.name, fo.relPath,
                   (SELECT COUNT(DISTINCT f.assetId) FROM file f JOIN asset a ON a.id = f.assetId
                     WHERE f.folderId = fo.id AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id)) AS count,
                   (SELECT a.id FROM file f JOIN asset a ON a.id = f.assetId
                     WHERE f.folderId = fo.id AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id) ORDER BY a.takenAt DESC LIMIT 1) AS coverId
            FROM folder fo ORDER BY fo.root, fo.relPath
            """)
        return rows.map { FolderNode(id: $0["id"], root: $0["root"], parentId: $0["parentId"], name: $0["name"], relPath: $0["relPath"],
                                     count: $0["count"], coverId: $0["coverId"]) }
    }

    public func asset(id: String) throws -> AssetDetail? {
        try db.writer.read { d in
            guard let a = try Asset.fetchOne(d, key: id) else { return nil }
            let files = try String.fetchAll(d, sql: "SELECT relPath FROM file WHERE assetId = ? ORDER BY relPath", arguments: [id])
            let faces = try Row.fetchAll(d, sql: "SELECT id, assetId, personId, x, y, w, h FROM face WHERE assetId = ? ORDER BY x",
                                         arguments: [id]).map(FaceService.info)
            let place = try a.placeId.flatMap { pid in try PlaceService.catalogPlaces(d).first { $0.id == pid } }
            return AssetDetail(asset: a, files: files, faces: faces, place: place,
                               text: try TextService.text(d, assetId: id))
        }
    }

    /// The original's file name (from the catalog: the file itself isn't read).
    public func originalName(id: String) throws -> String? {
        try db.writer.read {
            try String.fetchOne($0, sql: "SELECT COALESCE(name, relPath) FROM file WHERE assetId = ? ORDER BY root, relPath LIMIT 1", arguments: [id])
        }.map { ($0 as NSString).lastPathComponent }
    }

    /// "photo" or "video"; nil for an unknown asset.
    public func kind(id: String) throws -> String? {
        try db.writer.read { try String.fetchOne($0, sql: "SELECT kind FROM asset WHERE id = ?", arguments: [id]) }
    }

    /// The asset's database record alone (no files, faces or place).
    public func record(id: String) throws -> Asset? {
        try db.writer.read { try Asset.fetchOne($0, key: id) }
    }

    /// The still's Live Photo motion row.
    public func motion(id: String) throws -> MotionRow? {
        try db.writer.read { try MotionRow.fetchOne($0, key: id) }
    }

    /// Where a photo's (first) file is, also for photos in the uploads Trash.
    public func fileURL(id: String) throws -> URL? {
        let bases = try rootURLs()
        let row = try db.writer.read { try FileRow.filter(Column("assetId") == id).order(Column("root"), Column("relPath")).fetchOne($0) }
        return row.flatMap { r in bases[r.root].map { $0.appendingPathComponent(r.relPath) } }
    }

    /// Where a folder is on disk.
    public func folderURL(id: Int64) throws -> URL? {
        let bases = try rootURLs()
        guard let f = try db.writer.read({ try Folder.fetchOne($0, key: id) }) else { return nil }
        return bases[f.root].map { f.relPath.isEmpty ? $0 : $0.appendingPathComponent(f.relPath) }
    }

    public func rootURLs() throws -> [String: URL] {
        try LocalOriginalStore.rootURLs(settings)
    }
}
