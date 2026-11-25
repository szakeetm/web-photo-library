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

    public static func placeholder(id: String) -> Asset {
        Asset(id: id, width: 0, height: 0, mime: "", takenAt: Date(timeIntervalSince1970: 0), tzOffset: nil,
              dateSource: "file", lat: nil, lon: nil, locationSource: nil, cameraMake: nil, cameraModel: nil,
              lens: nil, iso: nil, aperture: nil, shutter: nil, focal: nil, description: nil, favorite: false,
              favoriteUserSet: false, blurhash: nil, editVersion: 0, missingSince: nil)
    }
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

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Folder: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folder"
    public var id: Int64?
    public var relPath: String
    public var parentId: Int64?
    public var name: String

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
}
