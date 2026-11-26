import Foundation
import GRDB

/// The Trash for any photo. Uploads are moved there for real (`UploadTrash`: their files go to the
/// uploads folder's .trash). Every other photo — in local folders, a Photos library, an rclone folder —
/// is only hidden ("virtual"): its files are never touched. Restoring shows it again; deleting it for good
/// keeps it hidden for good (rescans don't bring it back). Deleting the source files too may come later.
public enum PhotoTrash {
    /// Whether every file of these photos is an upload (and so can really be moved).
    static func isUpload(_ id: String, _ d: Database) throws -> Bool {
        let roots = try String.fetchAll(d, sql: "SELECT root FROM file WHERE assetId = ? UNION SELECT root FROM motion WHERE assetId = ?",
                                        arguments: [id, id])
        return !roots.isEmpty && roots.allSatisfy { $0 == Roots.uploads }
    }

    /// Puts photos in the Trash: uploads moved (when the uploads folder is set), the rest hidden.
    public static func trash(ids: [String], db: AppDatabase, uploadsRoot: URL?) throws -> [String] {
        let ids = Array(Set(ids))
        let (uploads, others) = try db.writer.read { d -> ([String], [String]) in
            guard try ids.allSatisfy({ try Asset.fetchOne(d, key: $0) != nil }) else {
                throw UploadDeleteError.notFound(ids.first { (try? Asset.fetchOne(d, key: $0)) == nil } ?? "")
            }
            let already = Set(try String.fetchAll(d, sql: "SELECT assetId FROM trash"))
            let todo = ids.filter { !already.contains($0) }
            var up: [String] = [], other: [String] = []
            for id in todo { if uploadsRoot != nil, try isUpload(id, d) { up.append(id) } else { other.append(id) } }
            return (up, other)
        }
        var done: [String] = []
        if let uploadsRoot, !uploads.isEmpty { done += try UploadTrash.trash(ids: uploads, db: db, uploadsRoot: uploadsRoot) }
        if !others.isEmpty {
            try db.writer.write { d in
                for id in others {
                    try d.execute(sql: "INSERT OR IGNORE INTO trash (assetId, trashedAt, virtual) VALUES (?, ?, 1)", arguments: [id, Date()])
                    try ChangeLog.record(d, entity: "asset", id: id, op: "update")
                }
            }
            done += others
        }
        return done
    }

    /// Takes photos out of the Trash: uploads moved back, hidden ones shown again.
    public static func restore(ids: [String], db: AppDatabase, uploadsRoot: URL?) throws -> [String] {
        let hidden = Set(try db.writer.read { try String.fetchAll($0, sql: "SELECT assetId FROM trash WHERE virtual = 1 AND forever = 0") })
        let shown = Set(ids).intersection(hidden)
        if !shown.isEmpty {
            try db.writer.write { d in
                for id in shown {
                    try d.execute(sql: "DELETE FROM trash WHERE assetId = ?", arguments: [id])
                    try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
                }
            }
        }
        let rest = Set(ids).subtracting(hidden)
        let moved = try uploadsRoot.map { try UploadTrash.restore(ids: Array(rest), db: db, uploadsRoot: $0) } ?? []
        return Array(shown) + moved
    }

    /// Deletes Trash photos for good (all of them when `ids` is nil): uploads from disk, hidden ones stay
    /// hidden for good. Returns the photos whose cached images can go.
    public static func deleteForever(ids: [String]?, db: AppDatabase, uploadsRoot: URL?) throws -> [String] {
        let hidden = Set(try db.writer.read { try String.fetchAll($0, sql: "SELECT assetId FROM trash WHERE virtual = 1 AND forever = 0") })
        let chosen = ids.map { Set($0).intersection(hidden) } ?? hidden
        try hideForever(Array(chosen), db: db)
        let removed = try uploadsRoot.map { try UploadTrash.deleteForever(ids: ids.map { Array(Set($0).subtracting(hidden)) }, db: db, uploadsRoot: $0) } ?? []
        return Array(chosen) + removed
    }

    /// What has been in the Trash longer than `UploadTrash.keepDays` is deleted for good.
    public static func expire(db: AppDatabase, uploadsRoot: URL?, now: Date = Date()) throws -> [String] {
        let cutoff = now.addingTimeInterval(-Double(UploadTrash.keepDays) * 86_400)
        let old = try db.writer.read {
            try String.fetchAll($0, sql: "SELECT assetId FROM trash WHERE virtual = 1 AND forever = 0 AND trashedAt < ?", arguments: [cutoff])
        }
        try hideForever(old, db: db)
        let removed = try uploadsRoot.map { try UploadTrash.expire(db: db, uploadsRoot: $0, now: now) } ?? []
        return old + removed
    }

    static func hideForever(_ ids: [String], db: AppDatabase) throws {
        guard !ids.isEmpty else { return }
        try db.writer.write { d in
            for id in ids {
                try d.execute(sql: "UPDATE trash SET forever = 1 WHERE assetId = ?", arguments: [id])
                try ChangeLog.record(d, entity: "asset", id: id, op: "update")
            }
        }
    }

    public static func list(db: AppDatabase) throws -> [TrashItem] { try UploadTrash.list(db: db) }
}
