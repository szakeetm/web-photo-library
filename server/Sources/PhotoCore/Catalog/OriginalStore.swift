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
    /// The remote source the original would be fetched from before it can be read; nil when it is
    /// on this Mac already. Never fetches.
    func pendingFetch(id: String) throws -> RemoteSource?
    func prefetch(ids: [String], motionIds: [String], isCancelled: @escaping () -> Bool)
}

extension OriginalStore {
    public func pendingFetch(id: String) throws -> RemoteSource? { nil }
    /// Gets many originals (and Live Photo clips) onto this Mac ahead of reading them, in as few
    /// transfers as the store can; afterwards `original`/`motion` find them there. Best effort.
    public func prefetch(ids: [String], motionIds: [String], isCancelled: @escaping () -> Bool) {}
}

public enum OriginalStores {
    /// The store for this library (every `CatalogService` gets it unless given another).
    public static func make(db: AppDatabase, settings: SettingsStore) -> OriginalStore {
        LocalOriginalStore(db: db, settings: settings)
    }
}

/// Originals in the library and uploads folders on this Mac, read where they are; and those of
/// rclone sources, read from their mirror on this Mac, fetched into it first when they aren't there.
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
        for row in rows where !RemoteSources.isRemote(row.root) {
            if let url = Self.unchanged(bases[row.root], row.relPath, size: row.size, mtime: row.mtime) { return url }
        }
        // a remote source's copy: the files on this Mac are tried first
        for row in rows where RemoteSources.isRemote(row.root) {
            if let url = remote(row.root, row.relPath, size: row.size, mtime: row.mtime) { return url }
        }
        return nil
    }

    /// The remote source `original(id:)` would have to fetch the photo from first; nil when it is on
    /// this Mac already (or can't be had at all). Never fetches: lets clients say what they wait for.
    public func pendingFetch(id: String) throws -> RemoteSource? {
        let bases = try Self.rootURLs(settings)
        let rows = try db.writer.read { try FileRow.filter(Column("assetId") == id).order(Column("root"), Column("relPath")).fetchAll($0) }
        for row in rows where !RemoteSources.isRemote(row.root) {
            if Self.unchanged(bases[row.root], row.relPath, size: row.size, mtime: row.mtime) != nil { return nil }
        }
        guard let dataDir = db.directory else { return nil }
        var first: RemoteSource?
        for row in rows where RemoteSources.isRemote(row.root) {
            let url = RemoteSources.mirror(row.root, dataDir: dataDir).appendingPathComponent(row.relPath)
            if Self.matches(url, size: row.size, mtime: row.mtime) { return nil }
            if first == nil { first = try RemoteSources.source(root: row.root, settings) }
        }
        return first
    }

    /// Originals and motion clips that are only on remote sources are fetched with one batched rclone
    /// copy per source (parallel transfers, one process) instead of one `copyto` each. What fails here
    /// is simply fetched one by one when it's read.
    public func prefetch(ids: [String], motionIds: [String], isCancelled: @escaping () -> Bool) {
        guard let dataDir = db.directory, let rclone = Rclone.locate() else { return }
        // remote root → (relPath, the file on this Mac once fetched)
        var wanted: [String: [(rel: String, url: URL)]] = [:]
        do {
            let bases = try Self.rootURLs(settings)
            let rows = try db.writer.read { d in
                (try FileRow.filter(ids.contains(Column("assetId"))).order(Column("root"), Column("relPath")).fetchAll(d),
                 try MotionRow.filter(keys: motionIds).fetchAll(d))
            }
            // an original is wanted when no copy of it is on this Mac already
            for (_, group) in Dictionary(grouping: rows.0, by: \.assetId) {
                if group.contains(where: { !RemoteSources.isRemote($0.root) && Self.unchanged(bases[$0.root], $0.relPath, size: $0.size, mtime: $0.mtime) != nil }) { continue }
                let remote = group.filter { RemoteSources.isRemote($0.root) }
                let mirrored = remote.map { (row: $0, url: RemoteSources.mirror($0.root, dataDir: dataDir).appendingPathComponent($0.relPath)) }
                if mirrored.contains(where: { Self.matches($0.url, size: $0.row.size, mtime: $0.row.mtime) }) { continue }
                if let first = mirrored.first { wanted[first.row.root, default: []].append((first.row.relPath, first.url)) }
            }
            for m in rows.1 where RemoteSources.isRemote(m.root) {
                let url = RemoteSources.mirror(m.root, dataDir: dataDir).appendingPathComponent(m.relPath)
                if !Self.matches(url, size: m.size, mtime: m.mtime) { wanted[m.root, default: []].append((m.relPath, url)) }
            }
        } catch {
            return
        }
        for (root, files) in wanted where !isCancelled() {
            guard let source = try? RemoteSources.source(root: root, settings) else { continue }
            do {
                try rclone.copyFiles(files.map(\.rel), from: source.path, to: RemoteSources.mirror(root, dataDir: dataDir).path,
                                     transfers: 16, isCancelled: isCancelled)
            } catch {
                FileHandle.standardError.write(Data("Could not prefetch \(files.count) files from \(source.path): \(error)\n".utf8))
            }
            for f in files { OriginalsCache.touch(f.url) }
        }
        if !wanted.isEmpty {
            let budget = (try? RemoteSources.cacheBytes(settings)) ?? Int64(RemoteSources.defaultCacheGB) * 1_000_000_000
            OriginalsCache.evict(dataDir: dataDir, budget: budget, keep: Set(wanted.values.flatMap { $0.map(\.url.path) }))
        }
    }

    public func motion(id: String) throws -> URL? {
        guard let row = try db.writer.read({ try MotionRow.fetchOne($0, key: id) }) else { return nil }
        if RemoteSources.isRemote(row.root) { return remote(row.root, row.relPath, size: row.size, mtime: row.mtime) }
        return Self.unchanged(try Self.rootURLs(settings)[row.root], row.relPath, size: row.size, mtime: row.mtime)
    }

    /// A remote source's file from its mirror, fetched first when it isn't there (or isn't the same
    /// any more). Nil when it can't be had: no rclone, the remote unreachable, or the file changed.
    func remote(_ root: String, _ relPath: String, size: Int64, mtime: Double) -> URL? {
        guard let dataDir = db.directory, let source = try? RemoteSources.source(root: root, settings) else { return nil }
        let url = RemoteSources.mirror(root, dataDir: dataDir).appendingPathComponent(relPath)
        // one fetch of a file at a time; others wait for it
        Self.fetching.begin(url.path)
        defer { Self.fetching.end(url.path) }
        if Self.matches(url, size: size, mtime: mtime) {
            OriginalsCache.touch(url)
            return url
        }
        guard let rclone = Rclone.locate() else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rclone.copyFile(Rclone.join(source.path, relPath), to: url.path, quick: true)
        } catch {
            FileHandle.standardError.write(Data("Could not fetch \(relPath) from \(source.path): \(error)\n".utf8))
            return nil
        }
        guard Self.matches(url, size: size, mtime: mtime) else { return nil }
        OriginalsCache.touch(url)
        let budget = (try? RemoteSources.cacheBytes(settings)) ?? Int64(RemoteSources.defaultCacheGB) * 1_000_000_000
        OriginalsCache.evict(dataDir: dataDir, budget: budget, keep: [url.path])
        return url
    }

    /// A fetched file is the one scanned: same size, and the same modification time (rclone keeps the
    /// remote's; the catalog has it to the millisecond).
    static func matches(_ url: URL, size: Int64, mtime: Double) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? NSNumber)?.int64Value == size,
              let m = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return false }
        return abs(m - mtime) < 1
    }

    static let fetching = KeyedMutex()

    /// The folders on this Mac by root name: the library and uploads folders, and the originals of
    /// Apple Photos libraries.
    static func rootURLs(_ settings: SettingsStore) throws -> [String: URL] {
        var out = [
            Roots.library: try settings.get(.libraryPath).map { URL(fileURLWithPath: $0) },
            Roots.uploads: try settings.get(.uploadsPath).map { URL(fileURLWithPath: $0) },
        ].compactMapValues { $0 }
        for p in try PhotosLibraries.all(settings) { out[p.root] = p.url }
        for f in try LocalFolders.all(settings) { out[f.root] = f.url }
        return out
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

/// One holder per key at a time (a file being fetched).
final class KeyedMutex: @unchecked Sendable {
    private let cond = NSCondition()
    private var held = Set<String>()

    func begin(_ key: String) {
        cond.lock()
        while held.contains(key) { cond.wait() }
        held.insert(key)
        cond.unlock()
    }

    func end(_ key: String) {
        cond.lock()
        held.remove(key)
        cond.broadcast()
        cond.unlock()
    }
}
