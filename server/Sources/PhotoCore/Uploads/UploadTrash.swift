import Foundation
import GRDB

public enum UploadDeleteError: Error, Equatable, CustomStringConvertible {
    case notFound(String), notAnUpload(String), trashFailed(String)
    public var description: String {
        switch self {
        case .notFound(let id): "Photo \(id) doesn't exist."
        case .notAnUpload(let name): "\(name) isn't an upload. Only uploaded photos can be deleted; the library is never changed."
        case .trashFailed(let why): "Couldn't move the file to the Trash: \(why)"
        }
    }
}

public struct TrashItem: Codable, Sendable {
    public var asset: CatalogAsset
    /// When it was deleted, ISO-8601 UTC.
    public var trashedAt: String
}

/// The app's Trash for deleted uploads. Deleting only hides a photo (its file stays where it is);
/// it can be restored until it is deleted for good (by hand or after `keepDays`), when its file goes
/// to the macOS Trash and it leaves the catalog. Photos with any file outside the uploads folder
/// (i.e. in the library) are refused, so the library is never touched.
public enum UploadTrash {
    public static let keepDays = 30

    /// Moves uploaded photos to the Trash.
    public static func trash(ids: [String], db: AppDatabase) throws -> [String] {
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return [] }
        _ = try check(ids: ids, db: db)
        try db.writer.write { d in
            for id in ids {
                try d.execute(sql: "INSERT OR IGNORE INTO trash (assetId, trashedAt) VALUES (?, ?)", arguments: [id, Date()])
                try ChangeLog.record(d, entity: "asset", id: id, op: "update")
            }
        }
        return ids
    }

    /// Puts photos back where they were (albums, favourites and edits were kept).
    public static func restore(ids: [String], db: AppDatabase) throws -> [String] {
        try db.writer.write { d in
            var done: [String] = []
            for id in Set(ids) {
                try d.execute(sql: "DELETE FROM trash WHERE assetId = ?", arguments: [id])
                if d.changesCount > 0 {
                    try ChangeLog.record(d, entity: "asset", id: id, op: "update")
                    done.append(id)
                }
            }
            return done
        }
    }

    /// Everything in the Trash, most recently deleted first.
    public static func list(db: AppDatabase) throws -> [TrashItem] {
        try db.writer.read { d in
            let dates = Dictionary(uniqueKeysWithValues: try Row.fetchAll(d, sql: "SELECT assetId, trashedAt FROM trash").map {
                ($0["assetId"] as String, $0["trashedAt"] as Date)
            })
            return try CatalogService.catalogAssets(d, ids: nil, trashed: true)
                .compactMap { a in dates[a.id].map { (a, $0) } }
                .sorted { $0.1 > $1.1 }
                .map { TrashItem(asset: $0.0, trashedAt: CatalogService.iso.string(from: $0.1)) }
        }
    }

    /// Deletes photos in the Trash for good (all of them when `ids` is nil). Others are ignored.
    public static func deleteForever(ids: [String]?, db: AppDatabase, uploadsRoot: URL) throws -> [String] {
        let inTrash = Set(try db.writer.read { try String.fetchAll($0, sql: "SELECT assetId FROM trash") })
        let chosen = ids.map { Set($0).intersection(inTrash) } ?? inTrash
        return try purge(ids: Array(chosen), db: db, uploadsRoot: uploadsRoot)
    }

    /// Deletes for good what has been in the Trash longer than `keepDays`.
    public static func expire(db: AppDatabase, uploadsRoot: URL, now: Date = Date()) throws -> [String] {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        let old = try db.writer.read { try String.fetchAll($0, sql: "SELECT assetId FROM trash WHERE trashedAt < ?", arguments: [cutoff]) }
        return try purge(ids: old, db: db, uploadsRoot: uploadsRoot)
    }

    /// The photos' files and catalog rows, after checking every one is an upload.
    static func check(ids: [String], db: AppDatabase, requireFiles: Bool = true) throws -> ([FileRow], [MotionRow]) {
        try db.writer.read { d -> ([FileRow], [MotionRow]) in
            var files: [FileRow] = []
            for id in ids {
                let rows = try FileRow.filter(Column("assetId") == id).fetchAll(d)
                guard !rows.isEmpty || !requireFiles else { throw UploadDeleteError.notFound(id) }
                if let outside = rows.first(where: { $0.root != Roots.uploads }) {
                    throw UploadDeleteError.notAnUpload((outside.relPath as NSString).lastPathComponent)
                }
                files += rows
            }
            let motions = try MotionRow.filter(ids.contains(Column("assetId"))).fetchAll(d)
            if let outside = motions.first(where: { $0.root != Roots.uploads }) {
                throw UploadDeleteError.notAnUpload((outside.relPath as NSString).lastPathComponent)
            }
            return (files, motions)
        }
    }

    /// Files to the macOS Trash, then the photos leave the catalog.
    static func purge(ids: [String], db: AppDatabase, uploadsRoot: URL) throws -> [String] {
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return [] }
        let root = uploadsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let (files, motions) = try check(ids: ids, db: db, requireFiles: false)  // a file may have vanished meanwhile
        let paths = files.flatMap { [$0.relPath] + ($0.sidecarRelPath.map { [$0] } ?? []) } + motions.map(\.relPath)
        var urls: [URL] = []
        for rel in paths {
            let url = root.appendingPathComponent(rel).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { throw UploadDeleteError.notAnUpload(rel) }
            urls.append(url)
        }

        // 2. Files to the Trash (already gone is fine).
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
                throw UploadDeleteError.trashFailed(error.localizedDescription)
            }
        }

        // 3. Catalog: the photos, their album memberships, edits, faces, clips; then emptied folders.
        try db.writer.write { d in
            let list = ids.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
            for id in ids { try ChangeLog.record(d, entity: "asset", id: id, op: "delete") }
            for table in ["album_asset", "edit", "face", "motion", "file", "trash"] {
                try d.execute(sql: "DELETE FROM \(table) WHERE assetId IN (\(list))")
            }
            try d.execute(sql: "DELETE FROM search_index WHERE assetId IN (\(list))")
            try d.execute(sql: "DELETE FROM asset WHERE id IN (\(list))")

            var candidates = Set(files.map(\.folderId))
            while !candidates.isEmpty {
                var parents = Set<Int64>()
                for fid in candidates {
                    guard let f = try Folder.fetchOne(d, key: fid), f.root == Roots.uploads, !f.relPath.isEmpty,
                          try FileRow.filter(Column("folderId") == fid).fetchCount(d) == 0,
                          try Folder.filter(Column("parentId") == fid).fetchCount(d) == 0 else { continue }
                    try f.delete(d)
                    try ChangeLog.record(d, entity: "folder", id: String(fid), op: "delete")
                    if let p = f.parentId { parents.insert(p) }
                }
                candidates = parents
            }
        }
        return ids
    }
}
