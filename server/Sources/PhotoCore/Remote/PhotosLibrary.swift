import Foundation
import GRDB

/// An Apple Photos library (a .photoslibrary package on this Mac) as a source, read-only. Each of its
/// own photos is indexed where it is, as Photos shows it: an edited photo's rendered version
/// (resources/renders/…_1_201_a.heic, a video's …_2_0_a.mov, a Live Photo clip's …_2_100_a.mov) stands
/// for its original, and edits made here go on top of it; an unedited one is its original
/// (originals/<0-F>/<UUID>.<ext>). Files are named with their original names, and the library's albums
/// become albums here. Shared albums (reduced copies, not originals) are left out.
public struct PhotosLibrarySource: Codable, Sendable, Equatable {
    public var id: Int
    /// the .photoslibrary package
    public var path: String

    public init(id: Int, path: String) {
        self.id = id
        self.path = path
    }

    public var root: String { PhotosLibraries.rootPrefix + String(id) }
    /// The root's folder: the package (files are under originals/ and resources/renders/).
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
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

extension SettingKey where T == [String] {
    /// Photos libraries (roots) whose dates taken from Photos were read again from the files once, since
    /// a file's own date within a minute of Photos' stays.
    public static let photosDatesReread = SettingKey("photosDatesReread", default: [])
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

    /// Removes a library: its files and folders are forgotten, and the photos only there are removed for
    /// good with everything about them (album memberships, edits, Trash…); its albums here stay. Nothing
    /// in the library is touched. Returns the removed photos.
    @discardableResult
    public static func remove(id: Int, db: AppDatabase, _ settings: SettingsStore) throws -> [String] {
        var list = try all(settings)
        guard let s = list.first(where: { $0.id == id }) else { return [] }
        let purged = try AssetPurge.removeRoot(s.root, scanner: LibraryScanner(db: db, root: s.url, rootName: s.root), db: db)
        list.removeAll { $0.id == id }
        try settings.set(.photosLibraries, list)
        try settings.set(.photosLibraryStats, try settings.get(.photosLibraryStats).filter { $0.root != s.root })
        try settings.set(.sourceScans, try settings.get(.sourceScans).filter { $0.root != s.root })
        return purged
    }

    /// The file standing for an item: its rendered version when edited in Photos, else its original;
    /// and its Live Photo clip, the same way. Paths are inside the package; nil when not on disk.
    static func files(of item: PhotosLibraryReader.Item, in library: URL) -> (main: String?, motion: String?) {
        let fm = FileManager.default
        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: library.appendingPathComponent(rel).path) }
        let renders = "resources/renders/\(item.directory)/\(item.uuid)"
        let original = "originals/\(item.directory)/\(item.fileName)"
        var main: String?
        if item.edited {
            let candidates = item.isVideo ? [renders + "_2_0_a.mov"] : [renders + "_1_201_a.heic", renders + "_1_201_a.jpeg"]
            main = candidates.first(where: exists)
        }
        if main == nil, exists(original) { main = original }
        var motion: String?
        if !item.isVideo {
            let clip = "originals/\(item.directory)/\((item.fileName as NSString).deletingPathExtension)_3.mov"
            if item.edited, exists(renders + "_2_100_a.mov") { motion = renders + "_2_100_a.mov" } else if exists(clip) { motion = clip }
        }
        return (main, motion)
    }

    /// Scans a library: indexes its own photos as Photos shows them (edited ones by their rendered
    /// version), names them, and brings its albums.
    public static func scan(_ source: PhotosLibrarySource, db: AppDatabase, settings: SettingsStore, serverTZ: TimeZone,
                            progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> (ScanReport, [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.url.appendingPathComponent("database").path) else { throw ScanError.rootUnreadable(source.path) }
        let content = try PhotosLibraryReader.read(source.url)
        let scanner = LibraryScanner(db: db, root: source.url, rootName: source.root, serverTZ: serverTZ)

        // which file stands for each photo
        var chosen: [String: (main: String, motion: String?, name: String?)] = [:]
        for item in content.items.values {
            if isCancelled() { throw ScanError.cancelled }
            let f = files(of: item, in: source.url)
            guard let main = f.main else { continue }
            // an edited photo keeps its original name with its render's type (IMG_1234.HEIC → IMG_1234.jpeg)
            var name = item.originalName
            if let n = name, main.hasPrefix("resources/renders/") {
                name = (n as NSString).deletingPathExtension + "." + (main as NSString).pathExtension
            }
            chosen[item.uuid] = (main, f.motion, name)
        }

        // a photo edited (or reverted) in Photos since the last scan stands for itself under its new file:
        // its row moves there first, so its albums, edits and people follow it like a changed file
        try db.writer.write { d in
            for row in try FileRow.filter(Column("root") == source.root).fetchAll(d) {
                guard let c = chosen[PhotosLibraryReader.uuid(of: row.relPath)], c.main != row.relPath else { continue }
                if try FileRow.filter(Column("root") == source.root && Column("relPath") == c.main).fetchCount(d) == 0 {
                    try d.execute(sql: "UPDATE file SET relPath = ? WHERE id = ?", arguments: [c.main, row.id])
                }
            }
            for m in try MotionRow.filter(Column("root") == source.root).fetchAll(d) {
                guard let c = chosen[PhotosLibraryReader.uuid(of: m.relPath)], let clip = c.motion, clip != m.relPath else { continue }
                try d.execute(sql: "UPDATE motion SET relPath = ? WHERE assetId = ?", arguments: [clip, m.assetId])
            }
        }

        func candidate(_ rel: String) -> LibraryScanner.Candidate? {
            let url = source.url.appendingPathComponent(rel)
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return LibraryScanner.Candidate(relPath: rel, url: url, size: Int64(v.fileSize ?? 0),
                                            mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        var images: [LibraryScanner.Candidate] = [], videos: [LibraryScanner.Candidate] = []
        var dirs = Set([""])
        for c in chosen.values {
            for rel in [c.main] + (c.motion.map { [$0] } ?? []) {
                guard let cand = candidate(rel) else { continue }
                let ext = (rel as NSString).pathExtension.lowercased()
                if LibraryScanner.videoExtensions.contains(ext) { videos.append(cand) } else { images.append(cand) }
                var p = (rel as NSString).deletingLastPathComponent
                while !p.isEmpty && !dirs.contains(p) { dirs.insert(p); p = (p as NSString).deletingLastPathComponent }
            }
        }
        scanner.listing = (Array(dirs), images.sorted { $0.relPath < $1.relPath }, videos.sorted { $0.relPath < $1.relPath }, [], 0)
        var report = try scanner.detectChanges(progress: progress, isCancelled: isCancelled)

        // original names, albums, and the top folder named after the library
        let names = Dictionary(chosen.values.compactMap { c in c.name.map { (c.main, $0) } }, uniquingKeysWith: { a, _ in a })
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
        // dates and places as Photos shows them (the files can't say: see `Item.date`)
        let byMain = Dictionary(chosen.compactMap { uuid, c in content.items[uuid].map { (c.main, $0) } }, uniquingKeysWith: { a, _ in a })
        let reread = try settings.get(.photosDatesReread)
        if !reread.contains(source.root) {
            // dates taken from Photos by an earlier version even when the file's was only seconds off: read the files again
            try rereadPhotosDates(scanner: scanner, root: source.root, db: db)
        }
        report.updated += try applyPhotosMetadata(byMain, root: source.root, db: db, serverTZ: serverTZ)
        if !reread.contains(source.root) { try settings.set(.photosDatesReread, reread + [source.root]) }
        let albums = try importAlbums(content.albums, source: source, db: db, settings: settings)

        let stats = PhotosLibraryStats(root: source.root, items: content.items.count, onDisk: chosen.count,
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

    /// Gives each photo of the library the date and place Photos shows for it, over what was read from
    /// its file: a photo saved from WhatsApp, Signal, Messages, a browser… has no date in its file (it
    /// would get the day it reached this Mac), an edited photo's rendered version has neither date nor
    /// place, and Photos keeps a date or place adjusted there. A date set here stays the user's. The
    /// time zone is Photos' when it knows it, else the file's. Returns how many photos changed.
    static func applyPhotosMetadata(_ items: [String: PhotosLibraryReader.Item], root: String, db: AppDatabase,
                                    serverTZ: TimeZone) throws -> Int {
        try db.writer.write { d in
            var changed = 0
            var done = Set<String>()
            for row in try FileRow.filter(Column("root") == root).fetchAll(d) {
                guard let item = items[row.relPath], done.insert(row.assetId).inserted,
                      var a = try Asset.fetchOne(d, key: row.assetId) else { continue }
                let before = a
                if let date = item.date {
                    // the same moment as the file says: keep its source and zone. Photos often keeps a date a
                    // few seconds before the camera's: the camera's stays; a file's own date (the day it was
                    // saved) is never the photo's
                    let tolerance: TimeInterval = a.fileDateSource == "exif" || a.fileDateSource == "sidecar" ? 60 : 1
                    let same = a.fileTakenAt.map { abs($0.timeIntervalSince(date)) < tolerance } ?? false
                    if !same {
                        a.fileTakenAt = date
                        a.fileDateSource = "photos"
                        a.fileTzOffset = item.tzOffset ?? serverTZ.secondsFromGMT(for: date)
                    } else if let tz = item.tzOffset {
                        a.fileTzOffset = tz
                    }
                    try MetadataService.applyOverride(d, to: &a)
                }
                if let la = item.lat, let lo = item.lon,
                   a.lat.map({ abs($0 - la) > 1e-4 }) ?? true || a.lon.map({ abs($0 - lo) > 1e-4 }) ?? true {
                    (a.lat, a.lon, a.locationSource) = (la, lo, "photos")
                    a.placeVersion = 0   // named again for its new place
                }
                guard a != before else { continue }
                try a.update(d)
                try ChangeLog.record(d, entity: "asset", id: a.id, op: "upsert")
                changed += 1
            }
            return changed
        }
    }

    /// Reads again, from the files, the dates and places of the photos dated by Photos.
    static func rereadPhotosDates(scanner: LibraryScanner, root: String, db: AppDatabase) throws {
        let rows = try db.writer.read { d in
            try FileRow.fetchAll(d, sql: """
                SELECT f.* FROM file f JOIN asset a ON a.id = f.assetId WHERE f.root = ? AND a.fileDateSource = 'photos'
                """, arguments: [root])
        }
        var entries: [String: Set<String>] = [:]
        for row in rows {
            let url = scanner.root.appendingPathComponent(row.relPath)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? row.mtime
            _ = try scanner.refreshMetadata(row, url: url, mtime: mtime, dirEntries: &entries)
        }
    }

    /// The library's albums as albums here (matched again on the next scan by their Photos id): new
    /// photos are added; photos removed here stay removed only until the album changes in Photos.
    static func importAlbums(_ albums: [PhotosLibraryReader.Album], source: PhotosLibrarySource, db: AppDatabase,
                             settings: SettingsStore) throws -> (created: Int, updated: Int) {
        let service = AlbumService(db: db, settings: settings)
        let byUUID = try db.writer.read { d in
            Dictionary(try FileRow.filter(Column("root") == source.root).fetchAll(d).map { (PhotosLibraryReader.uuid(of: $0.relPath), $0.assetId) },
                       uniquingKeysWith: { a, _ in a })
        }
        var created = 0, updated = 0
        for album in albums {
            var seen = Set<String>()
            let ids = album.members.compactMap { byUUID[$0] }.filter { seen.insert($0).inserted }
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
        public var uuid: String
        /// originals/<directory>/<fileName> is the original
        public var directory: String
        public var fileName: String
        public var originalName: String?
        public var isVideo: Bool
        /// edited in Photos (its rendered version is shown there)
        public var edited: Bool
        /// The date and place as Photos shows them: what the file says, adjusted there, or for a photo
        /// without one (saved from WhatsApp, Signal, Messages…) when it was saved; an edited photo's
        /// rendered version has neither in the file.
        public var date: Date? = nil
        /// seconds east of UTC, when Photos knows the time zone
        public var tzOffset: Int? = nil
        public var lat: Double? = nil
        public var lon: Double? = nil
    }
    public struct Album: Sendable {
        public var uuid: String
        public var title: String
        /// members' UUIDs, oldest first
        public var members: [String]
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
                var byPK: [Int64: (uuid: String, date: Double)] = [:]
                let cols = Set(try Row.fetchAll(d, sql: "PRAGMA table_info(ZASSET)").map { $0["name"] as String })
                let xcols = Set(try Row.fetchAll(d, sql: "PRAGMA table_info(ZADDITIONALASSETATTRIBUTES)").map { $0["name"] as String })
                let edited = cols.contains("ZADJUSTMENTSSTATE") ? "COALESCE(a.ZADJUSTMENTSSTATE, 0)" : "0"
                let place = cols.contains("ZLATITUDE") && cols.contains("ZLONGITUDE") ? "a.ZLATITUDE AS lat, a.ZLONGITUDE AS lon" : "NULL AS lat, NULL AS lon"
                // the offset only counts with its zone's name: without one Photos doesn't know the zone
                let tz = xcols.contains("ZTIMEZONEOFFSET") && xcols.contains("ZTIMEZONENAME")
                    ? "CASE WHEN x.ZTIMEZONENAME IS NOT NULL AND x.ZTIMEZONENAME != '' THEN x.ZTIMEZONEOFFSET END AS tz" : "NULL AS tz"
                for r in try Row.fetchAll(d, sql: """
                    SELECT a.Z_PK AS pk, a.ZUUID AS uuid, a.ZDIRECTORY AS dir, a.ZFILENAME AS file, COALESCE(a.ZKIND, 0) AS kind,
                           \(edited) AS edited, a.ZDATECREATED AS date, x.ZORIGINALFILENAME AS original, \(place), \(tz)
                    FROM ZASSET a LEFT JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK
                    WHERE a.ZTRASHEDSTATE = 0 AND COALESCE(a.ZHIDDEN, 0) = 0 AND a.ZDIRECTORY IS NOT NULL AND a.ZFILENAME IS NOT NULL
                      AND COALESCE(a.ZVISIBILITYSTATE, 0) = 0   -- shared albums' photos are 2: reduced copies, not originals
                    """) {
                    let uuid = ((r["uuid"] as String?) ?? "").uppercased()
                    let date: Double? = r["date"]
                    var item = Item(uuid: uuid, directory: r["dir"], fileName: r["file"], originalName: r["original"],
                                    isVideo: (r["kind"] as Int) == 1, edited: (r["edited"] as Int) > 0)
                    item.date = date.map(Date.init(timeIntervalSinceReferenceDate:))
                    item.tzOffset = (r["tz"] as Int?).flatMap { abs($0) <= 14 * 3600 ? $0 : nil }
                    // no place: NULL, or -180 / 0,0 in older libraries
                    if let la: Double = r["lat"], let lo: Double = r["lon"], (-90...90).contains(la), (-180...180).contains(lo),
                       la != -180, lo != -180, !(la == 0 && lo == 0) {
                        (item.lat, item.lon) = (la, lo)
                    }
                    items[uuid] = item
                    byPK[r["pk"]] = (uuid, date ?? 0)
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
                            let uuids = (members[r["pk"]] ?? []).compactMap { byPK[$0] }.sorted { $0.date < $1.date }.map(\.uuid)
                            albums.append(Album(uuid: r["uuid"], title: r["title"], members: uuids))
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
