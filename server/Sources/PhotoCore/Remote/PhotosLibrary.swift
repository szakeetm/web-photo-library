import Foundation
import GRDB

/// An Apple Photos library (a .photoslibrary package on this Mac) as a source, read-only: its
/// originals are indexed where they are (originals/<0-F>/<UUID>.<ext>), named with their original
/// names, and its albums become albums here. Edits made in Photos aren't read (yet); shared albums
/// (reduced copies, not originals) are left out.
public struct PhotosLibrarySource: Codable, Sendable, Equatable {
    public var id: Int
    /// the .photoslibrary package
    public var path: String

    public init(id: Int, path: String) {
        self.id = id
        self.path = path
    }

    public var root: String { PhotosLibraries.rootPrefix + String(id) }
    public var originals: URL { URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("originals", isDirectory: true) }
    /// "Photos Library"
    public var title: String { (URL(fileURLWithPath: path).lastPathComponent as NSString).deletingPathExtension }
}

/// What the last scan of a Photos library found.
public struct PhotosLibraryStats: Codable, Sendable, Equatable {
    public var root: String
    /// own photos and videos (not deleted, not hidden; shared albums aren't counted)
    public var items: Int
    /// of those, how many have their original in the library (the rest are only in iCloud)
    public var onDisk: Int
    public var albums: Int
    public var scannedAt: Date
}

extension SettingKey where T == [PhotosLibrarySource] {
    public static let photosLibraries = SettingKey("photosLibraries", default: [])
}

extension SettingKey where T == [PhotosLibraryStats] {
    public static let photosLibraryStats = SettingKey("photosLibraryStats", default: [])
}

public enum PhotosLibraryError: Error, CustomStringConvertible {
    case notALibrary(String), unreadable(String)
    public var description: String {
        switch self {
        case .notALibrary(let p): "\(p) isn't an Apple Photos library (a .photoslibrary with database/Photos.sqlite and originals)."
        case .unreadable(let why): "The Photos library's database can't be read: \(why)"
        }
    }
}

public enum PhotosLibraries {
    public static let rootPrefix = "photos-"

    public static func isPhotos(_ root: String) -> Bool { root.hasPrefix(rootPrefix) }

    public static func all(_ settings: SettingsStore) throws -> [PhotosLibrarySource] { try settings.get(.photosLibraries) }

    public static func source(root: String, _ settings: SettingsStore) throws -> PhotosLibrarySource? {
        try all(settings).first { $0.root == root }
    }

    /// Checks `path` is a Photos library and adds it.
    public static func add(path: String, _ settings: SettingsStore) throws -> PhotosLibrarySource {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard url.pathExtension == "photoslibrary",
              fm.fileExists(atPath: url.appendingPathComponent("database/Photos.sqlite").path),
              fm.fileExists(atPath: url.appendingPathComponent("originals").path) else { throw PhotosLibraryError.notALibrary(path) }
        var list = try all(settings)
        let s = PhotosLibrarySource(id: (list.map(\.id).max() ?? 0) + 1, path: url.standardizedFileURL.path)
        list.append(s)
        try settings.set(.photosLibraries, list)
        return s
    }

    /// Removes a library: its files are forgotten (photos only there become missing), its folders
    /// deleted. Its albums here stay. Nothing in the library is touched.
    public static func remove(id: Int, db: AppDatabase, _ settings: SettingsStore) throws {
        var list = try all(settings)
        guard let s = list.first(where: { $0.id == id }) else { return }
        _ = try LibraryScanner(db: db, root: s.originals, rootName: s.root).finishBatches(present: [], videos: [], dirs: [])
        list.removeAll { $0.id == id }
        try settings.set(.photosLibraries, list)
        try settings.set(.photosLibraryStats, try settings.get(.photosLibraryStats).filter { $0.root != s.root })
    }

    /// Scans a library: indexes its own photos' originals (in place), names them, and brings its albums.
    public static func scan(_ source: PhotosLibrarySource, db: AppDatabase, settings: SettingsStore, serverTZ: TimeZone,
                            progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> (ScanReport, [String]) {
        let content = try PhotosLibraryReader.read(URL(fileURLWithPath: source.path))
        let scanner = LibraryScanner(db: db, root: source.originals, rootName: source.root, serverTZ: serverTZ)
        // only files of the library's own photos: not deleted ones, not hidden ones
        var walked = try scanner.walk(isCancelled: isCancelled)
        let keep = { (c: LibraryScanner.Candidate) in content.items[PhotosLibraryReader.uuid(of: c.relPath)] != nil }
        walked.images = walked.images.filter(keep)
        walked.videos = walked.videos.filter(keep)
        scanner.listing = walked
        var report = try scanner.detectChanges(progress: progress, isCancelled: isCancelled)
        report.skippedOther = 0

        // original names, albums, and the top folder named after the library
        let names = Dictionary(content.items.values.compactMap { i in i.originalName.map { (i.relPath, $0) } }, uniquingKeysWith: { a, _ in a })
        try db.writer.write { d in
            for row in try FileRow.filter(Column("root") == source.root).fetchAll(d) {
                let name = names[row.relPath]
                guard row.name != name else { continue }
                try d.execute(sql: "UPDATE file SET name = ? WHERE id = ?", arguments: [name, row.id])
                try ChangeLog.record(d, entity: "asset", id: row.assetId, op: "upsert")
            }
        }
        let rootId = try scanner.ensureFolders([""])[""]!
        try db.writer.write { d in
            if try String.fetchOne(d, sql: "SELECT name FROM folder WHERE id = ?", arguments: [rootId]) != source.title {
                try d.execute(sql: "UPDATE folder SET name = ? WHERE id = ?", arguments: [source.title, rootId])
                try ChangeLog.record(d, entity: "folder", id: String(rootId), op: "upsert")
            }
        }
        let albums = try importAlbums(content.albums, source: source, db: db, settings: settings)

        let onDisk = Set(walked.images.map(\.relPath) + walked.videos.map(\.relPath))
        let stats = PhotosLibraryStats(root: source.root, items: content.items.count,
                                       onDisk: content.items.values.filter { onDisk.contains($0.relPath) }.count,
                                       albums: content.albums.count, scannedAt: Date())
        try settings.set(.photosLibraryStats, try settings.get(.photosLibraryStats).filter { $0.root != source.root } + [stats])
        var notes: [String] = []
        if albums.created + albums.updated > 0 {
            notes.append("\(source.title): \(albums.created) album\(albums.created == 1 ? "" : "s") added, \(albums.updated) updated.")
        }
        if stats.onDisk < stats.items {
            notes.append("\(source.title): \(stats.items - stats.onDisk) of \(stats.items) photos have no original in the library (in iCloud only: Photos → Settings → iCloud → Download Originals to this Mac).")
        }
        return (report, notes)
    }

    /// The library's albums as albums here (matched again on the next scan by their Photos id): new
    /// photos are added; photos removed here stay removed only until the album changes in Photos.
    static func importAlbums(_ albums: [PhotosLibraryReader.Album], source: PhotosLibrarySource, db: AppDatabase,
                             settings: SettingsStore) throws -> (created: Int, updated: Int) {
        let service = AlbumService(db: db, settings: settings)
        let byPath = try db.writer.read { d in
            Dictionary(try FileRow.filter(Column("root") == source.root).fetchAll(d).map { ($0.relPath, $0.assetId) }, uniquingKeysWith: { a, _ in a })
        }
        var created = 0, updated = 0
        for album in albums {
            var seen = Set<String>()
            let ids = album.relPaths.compactMap { byPath[$0] }.filter { seen.insert($0).inserted }
            guard !ids.isEmpty else { continue }
            let key = "\(source.root):\(album.uuid)"
            if let existing = try db.writer.read({ try Int64.fetchOne($0, sql: "SELECT id FROM album WHERE sourceKey = ?", arguments: [key]) }) {
                let have = Set(try service.members(id: existing))
                let new = ids.filter { !have.contains($0) }
                if !new.isEmpty {
                    try service.modify(id: existing, add: new, remove: [], order: nil)
                    updated += 1
                }
            } else {
                try service.create(title: album.title, assetIds: ids, source: "photos", sourceKey: key)
                created += 1
            }
        }
        return (created, updated)
    }
}

/// Reads an Apple Photos library's database (from a copy: Photos may be using it).
public enum PhotosLibraryReader {
    public struct Item: Sendable {
        /// the original's path inside originals/
        public var relPath: String
        public var originalName: String?
    }
    public struct Album: Sendable {
        public var uuid: String
        public var title: String
        /// members' paths inside originals/, oldest first
        public var relPaths: [String]
    }

    /// The UUID a file in originals/ belongs to ("9CD3…-…_3.mov" → "9CD3…-…").
    static func uuid(of relPath: String) -> String {
        let name = (relPath as NSString).lastPathComponent
        let end = name.firstIndex { $0 == "_" || $0 == "." } ?? name.endIndex
        return String(name[..<end]).uppercased()
    }

    /// Own photos and videos (not deleted, not hidden, not from shared albums) by UUID, and albums.
    public static func read(_ library: URL) throws -> (items: [String: Item], albums: [Album]) {
        let fm = FileManager.default
        let src = library.appendingPathComponent("database", isDirectory: true)
        let tmp = fm.temporaryDirectory.appendingPathComponent("photoslibrary-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        do {
            for s in ["", "-wal", "-shm"] where fm.fileExists(atPath: src.appendingPathComponent("Photos.sqlite" + s).path) {
                try fm.copyItem(at: src.appendingPathComponent("Photos.sqlite" + s), to: tmp.appendingPathComponent("Photos.sqlite" + s))
            }
        } catch {
            throw PhotosLibraryError.unreadable(error.localizedDescription)
        }
        do {
            let q = try DatabaseQueue(path: tmp.appendingPathComponent("Photos.sqlite").path)
            defer { try? q.close() }
            return try q.read { d in
                var items: [String: Item] = [:]
                var byPK: [Int64: (relPath: String, date: Double)] = [:]
                for r in try Row.fetchAll(d, sql: """
                    SELECT a.Z_PK AS pk, a.ZUUID AS uuid, a.ZDIRECTORY AS dir, a.ZFILENAME AS file,
                           COALESCE(a.ZDATECREATED, 0) AS date, x.ZORIGINALFILENAME AS original
                    FROM ZASSET a LEFT JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK
                    WHERE a.ZTRASHEDSTATE = 0 AND COALESCE(a.ZHIDDEN, 0) = 0 AND a.ZDIRECTORY IS NOT NULL AND a.ZFILENAME IS NOT NULL
                      AND COALESCE(a.ZVISIBILITYSTATE, 0) = 0   -- shared albums' photos are 2: reduced copies, not originals
                    """) {
                    let uuid = ((r["uuid"] as String?) ?? "").uppercased()
                    let rel = (r["dir"] as String) + "/" + (r["file"] as String)
                    items[uuid] = Item(relPath: rel, originalName: r["original"])
                    byPK[r["pk"]] = (rel, r["date"])
                }
                // albums: the album–asset join table's name depends on the Photos version (Z_26ASSETS, Z_34ASSETS…)
                var albums: [Album] = []
                if let join = try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z\\_%ASSETS' ESCAPE '\\'")
                    .first(where: { t in
                        let cols = (try? Row.fetchAll(d, sql: "PRAGMA table_info(\(t))").map { $0["name"] as String }) ?? []
                        return cols.contains { $0.hasSuffix("ALBUMS") && !$0.hasPrefix("Z_FOK") }
                    }) {
                    let cols = try Row.fetchAll(d, sql: "PRAGMA table_info(\(join))").map { $0["name"] as String }
                    if let albumCol = cols.first(where: { $0.hasSuffix("ALBUMS") && !$0.hasPrefix("Z_FOK") }),
                       let assetCol = cols.first(where: { $0.hasSuffix("ASSETS") && !$0.hasPrefix("Z_FOK") }) {
                        var members: [Int64: [Int64]] = [:]
                        for r in try Row.fetchAll(d, sql: "SELECT \(albumCol) AS al, \(assetCol) AS asset FROM \(join)") {
                            members[r["al"], default: []].append(r["asset"])
                        }
                        // user albums (kind 2), not deleted
                        for r in try Row.fetchAll(d, sql: """
                            SELECT Z_PK AS pk, ZUUID AS uuid, ZTITLE AS title FROM ZGENERICALBUM
                            WHERE ZKIND = 2 AND ZTRASHEDSTATE = 0 AND ZTITLE IS NOT NULL
                            """) {
                            let paths = (members[r["pk"]] ?? []).compactMap { byPK[$0] }.sorted { $0.date < $1.date }.map(\.relPath)
                            albums.append(Album(uuid: r["uuid"], title: r["title"], relPaths: paths))
                        }
                    }
                }
                return (items, albums)
            }
        } catch let e as PhotosLibraryError {
            throw e
        } catch {
            throw PhotosLibraryError.unreadable("\(error)")
        }
    }
}
