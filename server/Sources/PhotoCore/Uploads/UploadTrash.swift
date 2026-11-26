import Foundation
import GRDB

public enum UploadDeleteError: Error, Equatable, CustomStringConvertible {
    case notFound(String), notAnUpload(String), fileError(String)
    public var description: String {
        switch self {
        case .notFound(let id): "Photo \(id) doesn't exist."
        case .notAnUpload(let name): "\(name) isn't an upload. Only uploaded photos can be deleted; the library is never changed."
        case .fileError(let why): "Couldn't move or delete the file: \(why)"
        }
    }
}

public struct TrashItem: Codable, Sendable {
    public var asset: CatalogAsset
    /// When it was deleted, ISO-8601 UTC.
    public var trashedAt: String
    /// Only hidden: its files (not uploads) are where they were.
    public var virtual: Bool = false
}

/// The Trash for deleted uploads, kept in the uploads folder itself: deleting moves a photo's files
/// to `<uploads>/.trash/<id>/<original path>` (hidden, so scans ignore it) and hides the photo.
/// Restoring moves them back; deleting for good (by hand or after `keepDays`) removes them from disk.
/// Photos with any file outside the uploads folder (i.e. in the library) are refused, so the
/// library is never touched.
public enum UploadTrash {
    public static let keepDays = 30
    public static let dirName = ".trash"

    static func trashedRel(_ id: String, _ rel: String) -> String { "\(dirName)/\(id)/\(rel)" }
    static func originalRel(_ id: String, _ rel: String) -> String {
        let prefix = "\(dirName)/\(id)/"
        return rel.hasPrefix(prefix) ? String(rel.dropFirst(prefix.count)) : rel
    }

    /// Moves uploaded photos to the Trash.
    public static func trash(ids: [String], db: AppDatabase, uploadsRoot: URL) throws -> [String] {
        let already = Set(try db.writer.read { try String.fetchAll($0, sql: "SELECT assetId FROM trash") })
        let ids = Array(Set(ids).subtracting(already))
        guard !ids.isEmpty else { return [] }
        let (files, motions) = try check(ids: ids, db: db)
        let root = try rootURL(uploadsRoot)
        try relocate(files: files, motions: motions, root: root, db: db) { id, rel in trashedRel(id, rel) } record: { d in
            for id in ids {
                try d.execute(sql: "INSERT OR IGNORE INTO trash (assetId, trashedAt) VALUES (?, ?)", arguments: [id, Date()])
                try ChangeLog.record(d, entity: "asset", id: id, op: "update")
            }
        }
        return ids
    }

    /// Puts photos back where they were (albums, favourites and edits were kept).
    public static func restore(ids: [String], db: AppDatabase, uploadsRoot: URL) throws -> [String] {
        let inTrash = Set(try db.writer.read { try String.fetchAll($0, sql: "SELECT assetId FROM trash WHERE virtual = 0") })
        let ids = Array(Set(ids).intersection(inTrash))
        guard !ids.isEmpty else { return [] }
        let (files, motions) = try check(ids: ids, db: db, requireFiles: false)
        let root = try rootURL(uploadsRoot)
        try relocate(files: files, motions: motions, root: root, db: db) { id, rel in
            freeRel(originalRel(id, rel), root: root)
        } record: { d in
            for id in ids {
                try d.execute(sql: "DELETE FROM trash WHERE assetId = ?", arguments: [id])
                try ChangeLog.record(d, entity: "asset", id: id, op: "update")
            }
        }
        // the emptied folders under .trash/<id>/ (and .trash itself once empty)
        let left = files.flatMap { [$0.relPath] + ($0.sidecarRelPath.map { [$0] } ?? []) } + motions.map(\.relPath)
        for rel in left { removeEmptyDirs(from: root.appendingPathComponent((rel as NSString).deletingLastPathComponent), upTo: root) }
        return ids
    }

    /// Everything in the Trash, most recently deleted first.
    public static func list(db: AppDatabase) throws -> [TrashItem] {
        try db.writer.read { d in
            // photos deleted for good stay hidden but aren't in the Trash
            let rows = Dictionary(uniqueKeysWithValues: try Row.fetchAll(d, sql: "SELECT assetId, trashedAt, virtual FROM trash WHERE forever = 0").map {
                ($0["assetId"] as String, ($0["trashedAt"] as Date, $0["virtual"] as Bool))
            })
            return try CatalogService.catalogAssets(d, ids: nil, trashed: true)
                .compactMap { a in rows[a.id].map { (a, $0) } }
                .sorted { $0.1.0 > $1.1.0 }
                .map { TrashItem(asset: $0.0, trashedAt: CatalogService.iso.string(from: $0.1.0), virtual: $0.1.1) }
        }
    }

    /// Deletes photos in the Trash from disk (all of them when `ids` is nil). Others are ignored.
    public static func deleteForever(ids: [String]?, db: AppDatabase, uploadsRoot: URL) throws -> [String] {
        let inTrash = Set(try db.writer.read { try String.fetchAll($0, sql: "SELECT assetId FROM trash WHERE virtual = 0") })
        let chosen = ids.map { Set($0).intersection(inTrash) } ?? inTrash
        return try purge(ids: Array(chosen), db: db, uploadsRoot: uploadsRoot)
    }

    /// Deletes for good what has been in the Trash longer than `keepDays`.
    public static func expire(db: AppDatabase, uploadsRoot: URL, now: Date = Date()) throws -> [String] {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        let old = try db.writer.read {
            try String.fetchAll($0, sql: "SELECT assetId FROM trash WHERE virtual = 0 AND trashedAt < ?", arguments: [cutoff])
        }
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

    static func rootURL(_ uploadsRoot: URL) throws -> URL { uploadsRoot.standardizedFileURL.resolvingSymlinksInPath() }

    /// A path inside the uploads folder (refuses anything that would escape it).
    static func inside(_ root: URL, _ rel: String) throws -> URL {
        let url = root.appendingPathComponent(rel).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw UploadDeleteError.notAnUpload(rel) }
        return url
    }

    /// `rel`, or `name (2).ext`… when something else already took that place.
    static func freeRel(_ rel: String, root: URL) -> String {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) else { return rel }
        let dir = (rel as NSString).deletingLastPathComponent
        let name = (rel as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        for n in 2... {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let r = dir.isEmpty ? candidate : dir + "/" + candidate
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(r).path) { return r }
        }
        return rel
    }

    /// Moves the photos' files (photo, sidecar, Live Photo clip) to `target(id, relPath)` and updates
    /// their rows in the same step as `record`. Moves already made are undone if one fails.
    static func relocate(files: [FileRow], motions: [MotionRow], root: URL, db: AppDatabase,
                         target: (String, String) -> String, record: @escaping (Database) throws -> Void) throws {
        var moved: [(from: URL, to: URL)] = []
        func move(_ id: String, _ rel: String) throws -> String {
            let newRel = target(id, rel)
            let from = try inside(root, rel), to = try inside(root, newRel)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: from, to: to)
                moved.append((from, to))
            }
            return newRel
        }
        var newFiles: [FileRow] = [], newMotions: [MotionRow] = []
        do {
            for var f in files {
                f.relPath = try move(f.assetId, f.relPath)
                f.sidecarRelPath = try f.sidecarRelPath.map { try move(f.assetId, $0) }
                newFiles.append(f)
            }
            for m in motions {
                var n = m
                n.relPath = try move(m.assetId, m.relPath)
                newMotions.append(n)
            }
            try db.writer.write { d in
                for f in newFiles { try f.update(d) }
                for m in newMotions { try m.update(d) }
                try record(d)
            }
        } catch {
            for m in moved.reversed() { try? FileManager.default.moveItem(at: m.to, to: m.from) }
            if let e = error as? UploadDeleteError { throw e }
            throw UploadDeleteError.fileError(error.localizedDescription)
        }
    }

    /// Removes `dir` and then its parents while they are empty (ignoring .DS_Store), never `root` itself.
    static func removeEmptyDirs(from dir: URL, upTo root: URL) {
        var dir = dir.standardizedFileURL
        let fm = FileManager.default
        while dir.path.hasPrefix(root.path + "/") {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path), names.allSatisfy({ $0 == ".DS_Store" }) else { return }
            guard (try? fm.removeItem(at: dir)) != nil else { return }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// Deletes the files from disk, then the photos leave the catalog.
    static func purge(ids: [String], db: AppDatabase, uploadsRoot: URL) throws -> [String] {
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return [] }
        let root = try rootURL(uploadsRoot)
        let (files, motions) = try check(ids: ids, db: db, requireFiles: false)  // a file may have vanished meanwhile
        var urls: [URL] = []
        for f in files {
            urls.append(try inside(root, f.relPath))
            if let s = f.sidecarRelPath { urls.append(try inside(root, s)) }
        }
        for m in motions { urls.append(try inside(root, m.relPath)) }

        // 1. Files off the disk (already gone is fine), then their emptied folders.
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch {
                throw UploadDeleteError.fileError(error.localizedDescription)
            }
        }
        for url in urls { removeEmptyDirs(from: url.deletingLastPathComponent(), upTo: root) }
        for f in files {
            let original = (originalRel(f.assetId, f.relPath) as NSString).deletingLastPathComponent
            if !original.isEmpty { removeEmptyDirs(from: root.appendingPathComponent(original), upTo: root) }
        }

        // 2. Catalog: the photos, their album memberships, edits, faces, clips; then emptied folders.
        try db.writer.write { d in
            let list = ids.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
            for id in ids { try ChangeLog.record(d, entity: "asset", id: id, op: "delete") }
            try ChangeLog.recordAlbums(d, containing: ids)
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
                          !FileManager.default.fileExists(atPath: root.appendingPathComponent(f.relPath).path),
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
