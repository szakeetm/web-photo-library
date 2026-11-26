import Foundation
import GRDB

/// Forgets photos completely: their album memberships, edits, adjusted dates, trims, faces, recognised
/// objects and text, fingerprints, Live Photo clip and Trash entry go with them. Their files aren't
/// touched (the caller deletes cached images).
public enum AssetPurge {
    static let tables = ["album_asset", "edit", "face", "motion", "asset_object", "asset_text", "asset_print", "video_trim",
                         "meta_edit", "trash", "search_index", "file"]

    public static func purge(_ ids: [String], _ d: Database) throws {
        guard !ids.isEmpty else { return }
        let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        for a in ids { try ChangeLog.record(d, entity: "asset", id: a, op: "delete") }
        try ChangeLog.recordAlbums(d, containing: ids)
        for t in tables { try d.execute(sql: "DELETE FROM \(t) WHERE assetId IN (SELECT value FROM json_each(?))", arguments: [json]) }
        try d.execute(sql: "DELETE FROM asset WHERE id IN (SELECT value FROM json_each(?))", arguments: [json])
    }

    /// Removes a source's files from the catalog, then purges the photos that were only there.
    /// Returns the purged photos.
    static func removeRoot(_ root: String, scanner: LibraryScanner, db: AppDatabase) throws -> [String] {
        let before = try db.writer.read { try String.fetchAll($0, sql: "SELECT DISTINCT assetId FROM file WHERE root = ?", arguments: [root]) }
        _ = try scanner.finishBatches(present: [], videos: [], dirs: [])
        return try db.writer.write { d in
            let orphaned = try before.filter { try Int.fetchOne(d, sql: "SELECT count(*) FROM file WHERE assetId = ?", arguments: [$0]) == 0 }
            try purge(orphaned, d)
            return orphaned
        }
    }
}
