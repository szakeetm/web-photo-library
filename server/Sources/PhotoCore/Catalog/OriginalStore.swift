import Foundation
import GRDB

/// Where the bytes of originals (photos, videos, Live Photo clips) come from. Everything that reads
/// an original goes through here; everything else (thumbnails, previews, fingerprints, faces) is
/// derived data kept on this Mac.
///
/// Today originals are files in the library and uploads folders on this Mac (`LocalOriginalStore`).
/// A store can also keep them elsewhere (e.g. an rclone remote) and fetch them into a local cache on
/// demand, which is why `original` may block: call it from a background job or `blocking { }`, never
/// on the cooperative thread pool.
public protocol OriginalStore: Sendable {
    /// The photo's or video's original as a local file, ready to read. Nil when it isn't available:
    /// gone, or changed since the last scan (derivatives are never built from a file that changed).
    func original(id: String) throws -> URL?
    /// A Live Photo's motion clip, the same way.
    func motion(id: String) throws -> URL?
}

public enum OriginalStores {
    /// The store for this library (every `CatalogService` gets it unless given another).
    public static func make(db: AppDatabase, settings: SettingsStore) -> OriginalStore {
        LocalOriginalStore(db: db, settings: settings)
    }
}

/// Originals in the library and uploads folders on this Mac, read where they are.
public struct LocalOriginalStore: OriginalStore {
    let db: AppDatabase
    let settings: SettingsStore

    public init(db: AppDatabase, settings: SettingsStore) {
        self.db = db
        self.settings = settings
    }

    public func original(id: String) throws -> URL? {
        let bases = try Self.rootURLs(settings)
        let rows = try db.writer.read { try FileRow.filter(Column("assetId") == id).order(Column("root"), Column("relPath")).fetchAll($0) }
        for row in rows {
            if let url = Self.unchanged(bases[row.root], row.relPath, size: row.size, mtime: row.mtime) { return url }
        }
        return nil
    }

    public func motion(id: String) throws -> URL? {
        guard let row = try db.writer.read({ try MotionRow.fetchOne($0, key: id) }) else { return nil }
        return Self.unchanged(try Self.rootURLs(settings)[row.root], row.relPath, size: row.size, mtime: row.mtime)
    }

    /// The library and uploads folders, by root name.
    static func rootURLs(_ settings: SettingsStore) throws -> [String: URL] {
        [
            Roots.library: try settings.get(.libraryPath).map { URL(fileURLWithPath: $0) },
            Roots.uploads: try settings.get(.uploadsPath).map { URL(fileURLWithPath: $0) },
        ].compactMapValues { $0 }
    }

    /// The file under `base` when it is readable and its size and mtime still match the scan.
    static func unchanged(_ base: URL?, _ relPath: String, size: Int64, mtime: Double) -> URL? {
        guard let base else { return nil }
        let url = base.appendingPathComponent(relPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? NSNumber)?.int64Value == size,
              (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 == mtime,
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }
}
