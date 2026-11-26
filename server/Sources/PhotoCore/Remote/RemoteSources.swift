import Darwin
import Foundation
import GRDB

/// A library folder on an rclone remote (pCloud, S3, SFTP…), read-only: photos are listed and
/// fetched from it, never written to it.
public struct RemoteSource: Codable, Sendable, Equatable {
    /// Stable number; the root is "remote-<id>".
    public var id: Int
    /// rclone path, "remote:folder"
    public var path: String

    public init(id: Int, path: String) {
        self.id = id
        self.path = path
    }

    public var root: String { RemoteSources.rootPrefix + String(id) }

    /// A short name: the last folder of the path, or the remote's name.
    public var title: String {
        let colon = path.firstIndex(of: ":")
        let rest = colon.map { String(path[path.index(after: $0)...]) } ?? path
        let last = rest.split(separator: "/").last.map(String.init)
        return last ?? colon.map { String(path[..<$0]) } ?? path
    }
}

extension SettingKey where T == [RemoteSource] {
    /// Library folders on rclone remotes, scanned next to the library folder on this Mac.
    public static let remoteSources = SettingKey("remoteSources", default: [])
}

/// How the last scan of a source (an rclone folder or a Photos library) went.
public struct SourceScan: Codable, Sendable, Equatable {
    public var root: String
    public var at: Date
    public var ok: Bool
    public var added: Int
    public var updated: Int
    public var removed: Int
    public var unchanged: Int
    /// files that couldn't be read or fetched
    public var problems: Int
    /// why it failed, or what to know
    public var note: String?

    public init(root: String, at: Date = Date(), report: ScanReport?, note: String? = nil) {
        self.root = root
        self.at = at
        ok = report != nil
        added = report?.added ?? 0
        updated = report?.updated ?? 0
        removed = report?.removed ?? 0
        unchanged = report?.unchanged ?? 0
        problems = (report?.skipped ?? 0) + (report?.errors.count ?? 0)
        self.note = note
    }
}

extension SettingKey where T == [SourceScan] {
    public static let sourceScans = SettingKey("sourceScans", default: [])
}

extension SettingsStore {
    /// Records how a source's scan went.
    public func recordScan(_ scan: SourceScan) throws {
        try set(.sourceScans, try get(.sourceScans).filter { $0.root != scan.root } + [scan])
    }
}

extension SettingKey where T == Int? {
    /// Gigabytes of remote originals kept on this Mac (nil = `RemoteSources.defaultCacheGB`).
    public static let originalsCacheGB = SettingKey("originalsCacheGB", default: nil)
}

public enum RemoteSources {
    public static let rootPrefix = "remote-"
    public static let defaultCacheGB = 20

    public static func isRemote(_ root: String) -> Bool { root.hasPrefix(rootPrefix) }

    public static func all(_ settings: SettingsStore) throws -> [RemoteSource] { try settings.get(.remoteSources) }

    public static func source(root: String, _ settings: SettingsStore) throws -> RemoteSource? {
        try all(settings).first { $0.root == root }
    }

    /// Where a source's originals are kept on this Mac (only those fetched, plus its sidecars),
    /// with the source's folder layout and modification times.
    public static func mirror(_ root: String, dataDir: URL) -> URL {
        dataDir.appendingPathComponent("originals", isDirectory: true).appendingPathComponent(root, isDirectory: true)
    }

    public static func cacheBytes(_ settings: SettingsStore) throws -> Int64 {
        Int64(try settings.get(.originalsCacheGB) ?? defaultCacheGB) * 1_000_000_000
    }

    /// Removes a source: its files and folders are forgotten, and the photos only there are removed for
    /// good with everything about them (albums, edits, Trash…); its originals on this Mac are deleted.
    /// Nothing on the remote is touched. Returns the removed photos.
    @discardableResult
    public static func remove(id: Int, db: AppDatabase, _ settings: SettingsStore, dataDir: URL?) throws -> [String] {
        var list = try all(settings)
        guard let s = list.first(where: { $0.id == id }) else { return [] }
        let scanner = LibraryScanner(db: db, root: dataDir.map { mirror(s.root, dataDir: $0) } ?? URL(fileURLWithPath: "/"), rootName: s.root)
        let purged = try AssetPurge.removeRoot(s.root, scanner: scanner, db: db)
        list.removeAll { $0.id == id }
        try settings.set(.remoteSources, list)
        try settings.set(.sourceScans, try settings.get(.sourceScans).filter { $0.root != s.root })
        if let dataDir { try? FileManager.default.removeItem(at: mirror(s.root, dataDir: dataDir)) }
        return purged
    }

    /// Files (and their bytes) indexed per root.
    public static func fileCounts(_ db: AppDatabase) throws -> [String: (Int, Int64)] {
        try db.writer.read { d in
            Dictionary(try Row.fetchAll(d, sql: "SELECT root, count(*) AS n, COALESCE(sum(size), 0) AS b FROM file GROUP BY root")
                .map { ($0["root"] as String, ($0["n"] as Int, $0["b"] as Int64)) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Adds a source; returns it.
    public static func add(path: String, _ settings: SettingsStore) throws -> RemoteSource {
        var list = try all(settings)
        let s = RemoteSource(id: (list.map(\.id).max() ?? 0) + 1, path: path)
        list.append(s)
        try settings.set(.remoteSources, list)
        return s
    }
}

/// The originals of remote sources kept on this Mac: the least recently used are deleted when they
/// take more than the configured size. Sidecars (.json, .xmp) are tiny and always kept.
public enum OriginalsCache {
    static let lock = NSLock()
    nonisolated(unsafe) static var lastEviction = Date.distantPast

    /// Marks a file as just used (its access time; its modification time must stay the source's).
    public static func touch(_ url: URL) {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW)), timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
        _ = utimensat(AT_FDCWD, url.path, &times, 0)
    }

    static func isSidecar(_ url: URL) -> Bool { ["json", "xmp"].contains(url.pathExtension.lowercased()) }

    /// Bytes of originals kept (sidecars left out).
    public static func size(dataDir: URL) -> Int64 {
        files(dataDir).reduce(0) { $0 + $1.size }
    }

    static func files(_ dataDir: URL) -> [(url: URL, size: Int64, used: Date)] {
        let base = dataDir.appendingPathComponent("originals", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey]
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys) else { return [] }
        var out: [(URL, Int64, Date)] = []
        for case let f as URL in e where !isSidecar(f) {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append((f, Int64(v.fileSize ?? 0), v.contentAccessDate ?? .distantPast))
        }
        return out
    }

    /// Deletes the least recently used originals until they fit in `budget` bytes. `keep` are never
    /// deleted (files being used). At most once every `throttle` seconds unless `force`.
    public static func evict(dataDir: URL, budget: Int64, keep: Set<String> = [], force: Bool = false, throttle: TimeInterval = 60) {
        lock.lock()
        if !force && Date().timeIntervalSince(lastEviction) < throttle {
            lock.unlock()
            return
        }
        lastEviction = Date()
        lock.unlock()
        var all = files(dataDir)
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        guard total > budget else { return }
        all.sort { $0.used < $1.used }
        for f in all where total > budget && !keep.contains(f.url.path) {
            if (try? FileManager.default.removeItem(at: f.url)) != nil { total -= f.size }
        }
    }
}
