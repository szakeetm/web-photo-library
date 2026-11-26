import Foundation
import GRDB

public struct AlbumSummary: Codable, Sendable, Equatable {
    public var id: Int64
    public var title: String
    public var count: Int
    public var coverId: String?
    public var source: String  // user | takeout
    public var createdAt: Date
}

/// Album as shipped in the catalog: ordered member ids (members may include missing photos).
public struct CatalogAlbum: Codable, Sendable, Equatable {
    public var id: Int64
    public var title: String
    public var coverId: String?
    public var source: String
    public var assetIds: [String]
}

public enum AlbumError: Error, CustomStringConvertible {
    case notFound, emptyTitle
    public var description: String {
        switch self {
        case .notFound: "Album not found."
        case .emptyTitle: "Album title can't be empty."
        }
    }
}

/// Virtual albums, favourites and search — all user data, never touched by refresh jobs.
public final class AlbumService: Sendable {
    let db: AppDatabase
    let settings: SettingsStore
    /// Where rclone sources' sidecars are kept (for Takeout album titles); nil leaves those sources out.
    let dataDir: URL?

    public init(db: AppDatabase, settings: SettingsStore, dataDir: URL? = nil) {
        self.db = db
        self.settings = settings
        self.dataDir = dataDir
    }

    // MARK: Albums

    public func list() throws -> [AlbumSummary] {
        try db.writer.read { try Self.list($0) }
    }

    static func list(_ d: Database) throws -> [AlbumSummary] {
        try Row.fetchAll(d, sql: """
                SELECT al.id, al.title, al.source, al.createdAt,
                       (SELECT COUNT(*) FROM album_asset aa JOIN asset a ON a.id = aa.assetId
                         WHERE aa.albumId = al.id AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id)) AS count,
                       COALESCE((SELECT a.id FROM asset a WHERE a.id = al.coverAssetId AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id)),
                                (SELECT aa.assetId FROM album_asset aa JOIN asset a ON a.id = aa.assetId
                                  WHERE aa.albumId = al.id AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id) ORDER BY aa.position LIMIT 1)) AS coverId
                FROM album al ORDER BY al.title COLLATE NOCASE
                """).map {
                AlbumSummary(id: $0["id"], title: $0["title"], count: $0["count"], coverId: $0["coverId"],
                             source: $0["source"], createdAt: $0["createdAt"])
            }
    }

    /// All albums, or only those in `ids`.
    public func catalogAlbums(_ d: Database, ids: Set<Int64>? = nil) throws -> [CatalogAlbum] {
        var sql = "SELECT albumId, assetId FROM album_asset"
        var args: StatementArguments = []
        if let ids {
            sql += " WHERE albumId IN (SELECT value FROM json_each(?))"
            args = [String(decoding: try JSONEncoder().encode(Array(ids)), as: UTF8.self)]
        }
        let members = try Row.fetchAll(d, sql: sql + " ORDER BY albumId, position", arguments: args)
        var byAlbum: [Int64: [String]] = [:]
        for m in members { byAlbum[m["albumId"], default: []].append(m["assetId"]) }
        return try Self.list(d).filter { ids?.contains($0.id) ?? true }.map { CatalogAlbum(id: $0.id, title: $0.title, coverId: $0.coverId, source: $0.source, assetIds: byAlbum[$0.id] ?? []) }
    }

    @discardableResult
    public func create(title: String, assetIds: [String] = [], source: String = "user", sourceKey: String? = nil) throws -> AlbumSummary {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw AlbumError.emptyTitle }
        let id = try db.writer.write { d -> Int64 in
            try d.execute(sql: "INSERT INTO album (title, createdAt, source, sourceKey) VALUES (?, ?, ?, ?)",
                          arguments: [t, Date(), source, sourceKey])
            let id = d.lastInsertedRowID
            try Self.append(d, album: id, ids: assetIds)
            try ChangeLog.record(d, entity: "album", id: String(id), op: "upsert")
            return id
        }
        return try list().first { $0.id == id }!
    }

    public func update(id: Int64, title: String? = nil, coverAssetId: String? = nil) throws {
        try db.writer.write { d in
            guard try Int.fetchOne(d, sql: "SELECT 1 FROM album WHERE id = ?", arguments: [id]) != nil else { throw AlbumError.notFound }
            if let title {
                let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { throw AlbumError.emptyTitle }
                try d.execute(sql: "UPDATE album SET title = ? WHERE id = ?", arguments: [t, id])
            }
            if let coverAssetId { try d.execute(sql: "UPDATE album SET coverAssetId = ? WHERE id = ?", arguments: [coverAssetId, id]) }
            try ChangeLog.record(d, entity: "album", id: String(id), op: "upsert")
        }
    }

    public func delete(id: Int64) throws {
        try db.writer.write { d in
            try d.execute(sql: "DELETE FROM album WHERE id = ?", arguments: [id])
            guard d.changesCount > 0 else { throw AlbumError.notFound }
            try ChangeLog.record(d, entity: "album", id: String(id), op: "delete")
        }
    }

    public func members(id: Int64) throws -> [String] {
        try db.writer.read { try String.fetchAll($0, sql: "SELECT assetId FROM album_asset WHERE albumId = ? ORDER BY position", arguments: [id]) }
    }

    /// Adds (appending, ignoring existing members), removes, then optionally applies a full order.
    public func modify(id: Int64, add: [String], remove: [String], order: [String]?) throws {
        try db.writer.write { d in
            guard try Int.fetchOne(d, sql: "SELECT 1 FROM album WHERE id = ?", arguments: [id]) != nil else { throw AlbumError.notFound }
            try Self.append(d, album: id, ids: add)
            for a in remove { try d.execute(sql: "DELETE FROM album_asset WHERE albumId = ? AND assetId = ?", arguments: [id, a]) }
            if let order {
                // Listed ids first in the given order, any others keep their relative order after them.
                let current = try String.fetchAll(d, sql: "SELECT assetId FROM album_asset WHERE albumId = ? ORDER BY position", arguments: [id])
                let listed = order.filter(current.contains)
                let rest = current.filter { !listed.contains($0) }
                for (i, a) in (listed + rest).enumerated() {
                    try d.execute(sql: "UPDATE album_asset SET position = ? WHERE albumId = ? AND assetId = ?", arguments: [i, id, a])
                }
            }
            try ChangeLog.record(d, entity: "album", id: String(id), op: "upsert")
        }
    }

    static func append(_ d: Database, album: Int64, ids: [String]) throws {
        var next = (try Int.fetchOne(d, sql: "SELECT MAX(position) FROM album_asset WHERE albumId = ?", arguments: [album]) ?? -1) + 1
        for a in ids {
            try d.execute(sql: "INSERT OR IGNORE INTO album_asset (albumId, assetId, position) VALUES (?, ?, ?)", arguments: [album, a, next])
            if d.changesCount > 0 { next += 1 }
        }
    }

    // MARK: Favourites

    public func setFavorite(ids: [String], favorite: Bool) throws {
        try db.writer.write { d in
            for id in ids {
                try d.execute(sql: "UPDATE asset SET favorite = ?, favoriteUserSet = 1 WHERE id = ?", arguments: [favorite, id])
                try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
            }
        }
    }

    // MARK: Google Takeout album folders

    struct TakeoutFolder { let root: String; let relPath: String; let folderId: Int64; let title: String }

    /// Album folders of Google Takeout exports (a folder with a metadata.json that has a title) in
    /// every source: on this Mac (folders, uploads) and on rclone remotes, whose metadata.json was
    /// fetched with the folder's other sidecars when scanned.
    func takeoutFolders() throws -> [TakeoutFolder] {
        var bases = try LocalOriginalStore.rootURLs(settings)
        if let dataDir {
            for r in try RemoteSources.all(settings) { bases[r.root] = RemoteSources.mirror(r.root, dataDir: dataDir) }
        }
        let folders = try db.writer.read { try Folder.fetchAll($0) }
        return folders.compactMap { f in
            guard let base = bases[f.root] else { return nil }
            let dir = f.relPath.isEmpty ? base : base.appendingPathComponent(f.relPath)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("metadata.json")),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return nil }
            return TakeoutFolder(root: f.root, relPath: f.relPath, folderId: f.id!, title: title)
        }
    }

    /// A Takeout album folder, for choosing which to import.
    public struct TakeoutAlbum: Codable, Sendable, Equatable {
        /// identifies the folder: "<root>:<relPath>"
        public var key: String
        public var title: String
        /// where the folder is: its source's path, then the folder within it
        public var path: String
        /// photos and videos in the folder
        public var count: Int
        /// the album made from it earlier, if any
        public var albumId: Int64?
        /// photos in the folder that its album doesn't have yet (all of them when not imported)
        public var missing: Int
    }

    /// Every Takeout album folder, by path, with what importing it would do.
    public func takeoutAlbums() throws -> [TakeoutAlbum] {
        var sourcePaths = try LocalOriginalStore.rootURLs(settings).mapValues(\.path)
        for r in try RemoteSources.all(settings) { sourcePaths[r.root] = r.path }
        return try takeoutFolders().map { f in
            let key = "\(f.root):\(f.relPath)"
            let ids = try memberIds(of: f)
            let albumId = try db.writer.read { try Int64.fetchOne($0, sql: "SELECT id FROM album WHERE sourceKey = ?", arguments: [key]) }
            let have = Set(try albumId.map { try members(id: $0) } ?? [])
            let base = sourcePaths[f.root] ?? f.root
            return TakeoutAlbum(key: key, title: f.title, path: f.relPath.isEmpty ? base : base + "/" + f.relPath,
                                count: ids.count, albumId: albumId, missing: ids.filter { !have.contains($0) }.count)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func memberIds(of f: TakeoutFolder) throws -> [String] {
        try db.writer.read { d in
            try String.fetchAll(d, sql: """
                SELECT f.assetId FROM file f JOIN asset a ON a.id = f.assetId
                WHERE f.folderId = ? GROUP BY f.assetId ORDER BY MIN(a.takenAt)
                """, arguments: [f.folderId])
        }
    }

    /// Takeout album folders not yet imported as albums.
    public func pendingTakeoutAlbums() throws -> Int {
        let keys = Set(try db.writer.read { try String.fetchAll($0, sql: "SELECT sourceKey FROM album WHERE sourceKey IS NOT NULL") })
        return try takeoutFolders().filter { !keys.contains("\($0.root):\($0.relPath)") }.count
    }

    /// Creates an album per Takeout album folder (title from metadata.json), only for the folders in
    /// `keys` when given; re-runs only add new members.
    public func importTakeoutAlbums(keys: Set<String>? = nil) throws -> (created: Int, updated: Int) {
        var created = 0, updated = 0
        for f in try takeoutFolders() {
            let key = "\(f.root):\(f.relPath)"
            if let keys, !keys.contains(key) { continue }
            let ids = try memberIds(of: f)
            if let existing = try db.writer.read({ try Int64.fetchOne($0, sql: "SELECT id FROM album WHERE sourceKey = ?", arguments: [key]) }) {
                let before = try members(id: existing).count
                try modify(id: existing, add: ids, remove: [], order: nil)
                if try members(id: existing).count != before { updated += 1 }
            } else {
                try create(title: f.title, assetIds: ids, source: "takeout", sourceKey: key)
                created += 1
            }
        }
        return (created, updated)
    }

    // MARK: Search

    /// Photos matching every word (prefix match) in file names, folder paths, descriptions, album titles,
    /// places, people, recognised objects and text in the photos.
    public func search(_ query: String) throws -> [String] {
        // Split on anything that isn't a letter or digit, exactly like the FTS tokenizer does,
        // so "IMG_1234" or "louvre.jpg" become separate prefix terms (and can't inject syntax).
        let cleaned = String(query.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        let tokens = cleaned.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        try refreshSearchIndexIfStale()
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        return try db.writer.read { d in
            try String.fetchAll(d, sql: """
                SELECT s.assetId FROM search_index s JOIN asset a ON a.id = s.assetId
                WHERE search_index MATCH ? AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id) ORDER BY a.takenAt DESC
                """, arguments: [match])
        }
    }

    static let searchSeqKey = SettingKey<Int64>("searchIndexSeq", default: -1)

    func refreshSearchIndexIfStale() throws {
        let seq = try db.writer.read { try Int64.fetchOne($0, sql: "SELECT MAX(seq) FROM change_log") ?? 0 }
        guard seq != (try settings.get(Self.searchSeqKey)) else { return }
        try db.writer.write { d in
            try d.execute(sql: "DELETE FROM search_index")
            try d.execute(sql: """
                INSERT INTO search_index (assetId, text)
                SELECT a.id,
                       COALESCE(a.description, '') || ' ' ||
                       COALESCE((SELECT group_concat(COALESCE(f.name || ' ', '') || f.relPath, ' ') FROM file f WHERE f.assetId = a.id), '') || ' ' ||
                       COALESCE((SELECT group_concat(al.title, ' ') FROM album_asset aa JOIN album al ON al.id = aa.albumId
                                  WHERE aa.assetId = a.id), '') || ' ' ||
                       COALESCE((SELECT p.name || ' ' || COALESCE(p.region, '') || ' ' || p.country FROM place p WHERE p.id = a.placeId), '') || ' ' ||
                       COALESCE((SELECT group_concat(DISTINCT pe.name) FROM face fc JOIN person pe ON pe.id = fc.personId
                                  WHERE fc.assetId = a.id AND pe.hidden = 0 AND pe.name IS NOT NULL), '') || ' ' ||
                       COALESCE((SELECT group_concat(replace(l.name, '_', ' '), ' ') FROM asset_object ao
                                  JOIN object_label l ON l.id = ao.labelId WHERE ao.assetId = a.id), '') || ' ' ||
                       COALESCE((SELECT t.text FROM asset_text t WHERE t.assetId = a.id), '')
                FROM asset a WHERE a.missingSince IS NULL
                """)
        }
        try settings.set(Self.searchSeqKey, seq)
    }
}
