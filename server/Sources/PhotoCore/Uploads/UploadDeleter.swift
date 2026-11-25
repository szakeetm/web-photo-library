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

/// Deletes uploaded photos: their files in the uploads folder go to the Trash (recoverable there),
/// then the photos leave the catalog. Anything with a file outside the uploads folder (i.e. in the
/// library) is refused, so the library is never touched.
public enum UploadDeleter {
    public static func delete(ids: [String], db: AppDatabase, uploadsRoot: URL) throws -> [String] {
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return [] }
        let root = uploadsRoot.standardizedFileURL.resolvingSymlinksInPath()

        // 1. Check everything before touching any file.
        let (files, motions) = try db.writer.read { d -> ([FileRow], [MotionRow]) in
            var files: [FileRow] = []
            for id in ids {
                let rows = try FileRow.filter(Column("assetId") == id).fetchAll(d)
                guard !rows.isEmpty else { throw UploadDeleteError.notFound(id) }
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
            for table in ["album_asset", "edit", "face", "motion", "file"] {
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
