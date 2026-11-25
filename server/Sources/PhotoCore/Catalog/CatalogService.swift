import Foundation
import GRDB

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
}

/// Version of the catalog payload. Clients keeping an offline replica discard it when this changes.
public let catalogFormat = 1

public struct CatalogSnapshot: Codable, Sendable {
    public var format = catalogFormat
    public var seq: Int64
    public var assets: [CatalogAsset]
    public var folders: [FolderNode]
}

public struct FolderNode: Codable, Sendable, Equatable {
    public var id: Int64
    public var parentId: Int64?
    public var name: String
    public var relPath: String
    public var count: Int
    public var coverId: String?
}

public struct AssetDetail: Codable, Sendable {
    public var asset: Asset
    public var files: [String]
}

public final class CatalogService: Sendable {
    let db: AppDatabase
    let settings: SettingsStore

    public init(db: AppDatabase, settings: SettingsStore) {
        self.db = db
        self.settings = settings
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public func catalog() throws -> CatalogSnapshot {
        try db.writer.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT a.id, a.width, a.height, a.takenAt, a.tzOffset, a.favorite, a.blurhash, a.editVersion,
                       GROUP_CONCAT(f.folderId) AS folders, MIN(f.relPath) AS relPath
                FROM asset a JOIN file f ON f.assetId = a.id
                WHERE a.missingSince IS NULL
                GROUP BY a.id
                ORDER BY a.takenAt DESC, a.id
                """)
            let assets = rows.map { r -> CatalogAsset in
                let folders = ((r["folders"] as String?) ?? "").split(separator: ",").compactMap { Int64($0) }
                let rel: String = r["relPath"]
                return CatalogAsset(id: r["id"], w: r["width"], h: r["height"], t: Self.iso.string(from: r["takenAt"]),
                                    tz: r["tzOffset"], fav: r["favorite"], bh: r["blurhash"], ev: r["editVersion"],
                                    folders: Array(Set(folders)).sorted(), name: (rel as NSString).lastPathComponent)
            }
            let seq = try Int64.fetchOne(d, sql: "SELECT MAX(seq) FROM change_log") ?? 0
            return CatalogSnapshot(seq: seq, assets: assets, folders: try Self.folders(d))
        }
    }

    public func folderTree() throws -> [FolderNode] { try db.writer.read { try Self.folders($0) } }

    static func folders(_ d: Database) throws -> [FolderNode] {
        let rows = try Row.fetchAll(d, sql: """
            SELECT fo.id, fo.parentId, fo.name, fo.relPath,
                   (SELECT COUNT(DISTINCT f.assetId) FROM file f JOIN asset a ON a.id = f.assetId
                     WHERE f.folderId = fo.id AND a.missingSince IS NULL) AS count,
                   (SELECT a.id FROM file f JOIN asset a ON a.id = f.assetId
                     WHERE f.folderId = fo.id AND a.missingSince IS NULL ORDER BY a.takenAt DESC LIMIT 1) AS coverId
            FROM folder fo ORDER BY fo.relPath
            """)
        return rows.map { FolderNode(id: $0["id"], parentId: $0["parentId"], name: $0["name"], relPath: $0["relPath"],
                                     count: $0["count"], coverId: $0["coverId"]) }
    }

    public func asset(id: String) throws -> AssetDetail? {
        try db.writer.read { d in
            guard let a = try Asset.fetchOne(d, key: id) else { return nil }
            let files = try String.fetchAll(d, sql: "SELECT relPath FROM file WHERE assetId = ? ORDER BY relPath", arguments: [id])
            return AssetDetail(asset: a, files: files)
        }
    }

    /// Absolute URL of a readable original for the asset.
    public func sourceURL(id: String) throws -> URL? {
        guard let root = try settings.get(.libraryPath) else { return nil }
        let rels = try db.writer.read { try String.fetchAll($0, sql: "SELECT relPath FROM file WHERE assetId = ? ORDER BY relPath", arguments: [id]) }
        let base = URL(fileURLWithPath: root)
        return rels.map { base.appendingPathComponent($0) }.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }
}
