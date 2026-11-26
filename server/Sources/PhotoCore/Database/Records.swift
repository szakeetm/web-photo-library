import Foundation
import GRDB

public struct Asset: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "asset"
    public var id: String
    public var width: Int
    public var height: Int
    public var mime: String
    public var takenAt: Date
    public var tzOffset: Int?
    public var dateSource: String
    public var lat: Double?
    public var lon: Double?
    public var locationSource: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var iso: Double?
    public var aperture: Double?
    public var shutter: Double?
    public var focal: Double?
    public var description: String?
    public var favorite: Bool
    public var favoriteUserSet: Bool
    public var blurhash: String?
    public var editVersion: Int
    public var missingSince: Date?
    public var placeId: Int64? = nil
    public var placeVersion: Int = 0
    public var facesVersion: Int = 0
    public var kind: String = "photo"
    public var duration: Double? = nil
    public var videoCodec: String? = nil
    public var videoHDR: Bool = false
    public var servePlan: String? = nil
    public var videoError: String? = nil
    public var contentId: String? = nil
    public var probeVersion: Int = 0

    public static let currentProbeVersion = 1

    public static func placeholder(id: String) -> Asset {
        Asset(id: id, width: 0, height: 0, mime: "", takenAt: Date(timeIntervalSince1970: 0), tzOffset: nil,
              dateSource: "file", lat: nil, lon: nil, locationSource: nil, cameraMake: nil, cameraModel: nil,
              lens: nil, iso: nil, aperture: nil, shutter: nil, focal: nil, description: nil, favorite: false,
              favoriteUserSet: false, blurhash: nil, editVersion: 0, missingSince: nil)
    }
}

/// A Live Photo's paired video, attached to the still's asset instead of being an asset itself.
public struct MotionRow: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "motion"
    public var assetId: String
    public var root: String
    public var relPath: String
    public var size: Int64
    public var mtime: Double
    public var codec: String?
}

public struct FileRow: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "file"
    public var id: Int64?
    public var assetId: String
    public var relPath: String
    public var folderId: Int64
    public var size: Int64
    public var mtime: Double
    public var sidecarRelPath: String?
    public var root: String = Roots.library

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Folder: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folder"
    public var id: Int64?
    public var relPath: String
    public var parentId: Int64?
    public var name: String
    public var root: String = Roots.library

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct JobRow: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "job"
    public var id: Int64?
    public var kind: String
    public var state: String
    public var phase: String?
    public var progress: Int
    public var total: Int
    public var message: String?
    public var error: String?
    public var startedAt: Date?
    public var endedAt: Date?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum ChangeLog {
    public static func record(_ db: Database, entity: String, id: String, op: String) throws {
        try db.execute(sql: "INSERT INTO change_log (entity, entityId, op) VALUES (?, ?, ?)", arguments: [entity, id, op])
    }

    /// Drops all but the latest change of each item (see CatalogService.compactChangeLog).
    @discardableResult
    public static func compact(_ db: Database) throws -> Int {
        try db.execute(sql: "DELETE FROM change_log WHERE seq NOT IN (SELECT MAX(seq) FROM change_log GROUP BY entity, entityId)")
        return db.changesCount
    }

    /// Records a change of every album holding one of these photos (call before changing memberships).
    public static func recordAlbums(_ db: Database, containing assetIds: [String]) throws {
        guard !assetIds.isEmpty else { return }
        let json = String(decoding: try JSONEncoder().encode(assetIds), as: UTF8.self)
        for album in try Int64.fetchAll(db, sql: "SELECT DISTINCT albumId FROM album_asset WHERE assetId IN (SELECT value FROM json_each(?))",
                                        arguments: [json]) {
            try record(db, entity: "album", id: String(album), op: "upsert")
        }
    }
}
