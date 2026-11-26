import Foundation
import GRDB

/// What to export and how.
public struct ExportOptions: Codable, Sendable, Equatable {
    public enum Content: String, Codable, Sendable { case original, edited, both }
    public enum Sidecar: String, Codable, Sendable { case none, google, xmp }
    public enum Organize: String, Codable, Sendable { case flat, albums, years, months }

    /// Photos and videos (in this order), or albums, or the whole library.
    public var ids: [String]?
    public var albums: [Int64]?
    public var library: Bool?
    /// Originals as they are, with edits (pixels, dates, trims), or both (`Originals/` holds the
    /// originals of the edited ones).
    public var content: Content = .edited
    /// Format of rendered photo edits: "jpeg" or "heic".
    public var editFormat: String = "jpeg"
    /// Live Photos' videos next to their photos (same name, .MOV).
    public var livePhotoVideo: Bool = true
    public var sidecar: Sidecar = .none
    /// One folder per album, or `YYYY/YYYY-MM` folders by the photo's local date.
    public var organize: Organize = .flat

    public init() {}

    enum CodingKeys: String, CodingKey { case ids, albums, library, content, editFormat, livePhotoVideo, sidecar, organize }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ids = try c.decodeIfPresent([String].self, forKey: .ids)
        albums = try c.decodeIfPresent([Int64].self, forKey: .albums)
        library = try c.decodeIfPresent(Bool.self, forKey: .library)
        content = try c.decodeIfPresent(Content.self, forKey: .content) ?? .edited
        editFormat = try c.decodeIfPresent(String.self, forKey: .editFormat) ?? "jpeg"
        livePhotoVideo = try c.decodeIfPresent(Bool.self, forKey: .livePhotoVideo) ?? true
        sidecar = try c.decodeIfPresent(Sidecar.self, forKey: .sidecar) ?? .none
        organize = try c.decodeIfPresent(Organize.self, forKey: .organize) ?? .flat
    }

    public var format: ImageFormat { editFormat == "heic" ? .heic : .jpeg }
}

/// One file of an export.
public struct ExportEntry: Sendable {
    public enum Source: Sendable {
        /// The file as it is on disk.
        case original(assetId: String)
        /// The photo or video with its edits: rendered, date rewritten, or trimmed.
        case edited(assetId: String)
        /// A Live Photo's video, with the adjusted date when `dated`.
        case motion(assetId: String, dated: Bool)
        case data(Data)
    }
    public var path: String
    public var source: Source
    public var modified: Date
    /// The file's size: exact for originals and sidecars, the original's for edited files (an estimate).
    public var bytes: Int64 = 0

    public init(path: String, source: Source, modified: Date, bytes: Int64 = 0) {
        self.path = path
        self.source = source
        self.modified = modified
        if bytes == 0, case .data(let d) = source { self.bytes = Int64(d.count) } else { self.bytes = bytes }
    }

    /// The photo or video it comes from (nil for sidecars and other generated files).
    public var assetId: String? {
        switch source {
        case .original(let id), .edited(let id), .motion(let id, _): id
        case .data: nil
        }
    }
}

/// How big an export is: files, photos and videos, and bytes (edited files estimated at their original's size).
public struct ExportSummary: Codable, Sendable, Equatable {
    public var files: Int
    public var items: Int
    public var bytes: Int64

    public init(_ entries: [ExportEntry]) {
        files = entries.count
        items = Set(entries.compactMap(\.assetId)).count
        bytes = entries.reduce(0) { $0 + $1.bytes }
    }
}

public enum ExportError: Error, CustomStringConvertible {
    case empty, missing(String), cancelled
    public var description: String {
        switch self {
        case .empty: "Nothing to export."
        case .missing(let p): "A file isn't available (moved or changed since the last scan): \(p)"
        case .cancelled: "Export cancelled."
        }
    }
}

/// Plans exports (which files, where) and makes the files: originals as they are; edited photos
/// rendered (pixel edits) or with only their date rewritten (no re-encoding); videos trimmed and
/// dated without re-encoding; sidecars generated.
public final class ExportService: Sendable {
    let db: AppDatabase
    let catalog: CatalogService
    let edits: EditService
    let ffmpeg: URL?
    let workDir: URL

    public init(db: AppDatabase, catalog: CatalogService, edits: EditService, ffmpeg: URL?, cacheDir: URL) {
        self.db = db
        self.catalog = catalog
        self.edits = edits
        self.ffmpeg = ffmpeg
        workDir = cacheDir.appendingPathComponent("exports/work", isDirectory: true)
    }

    // MARK: Planning

    struct Item {
        let id: String
        let kind: String
        let ev: Int
        let dated: Bool
        let trim: (Double, Double)?
        let name: String
        let motionExt: String?
        let size: Int64
        let motionSize: Int64
        let info: ExportInfo
        var edited: Bool { ev > 0 || dated || trim != nil }
    }

    func items(_ ids: [String]) throws -> [String: Item] {
        guard !ids.isEmpty else { return [:] }
        let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        return try db.writer.read { d in
            var people: [String: [(String, Double, Double, Double, Double)]] = [:]
            for r in try Row.fetchAll(d, sql: """
                SELECT fc.assetId, pe.name, fc.x, fc.y, fc.w, fc.h FROM face fc JOIN person pe ON pe.id = fc.personId
                WHERE pe.name IS NOT NULL AND pe.hidden = 0 AND fc.assetId IN (SELECT value FROM json_each(?))
                """, arguments: [json]) {
                people[r["assetId"], default: []].append((r["name"], r["x"], r["y"], r["w"], r["h"]))
            }
            var albums: [String: [String]] = [:]
            for r in try Row.fetchAll(d, sql: """
                SELECT aa.assetId, al.title FROM album_asset aa JOIN album al ON al.id = aa.albumId
                WHERE aa.assetId IN (SELECT value FROM json_each(?))
                """, arguments: [json]) {
                albums[r["assetId"], default: []].append(r["title"])
            }
            var out: [String: Item] = [:]
            for r in try Row.fetchAll(d, sql: """
                SELECT a.*, (SELECT COALESCE(f.name, f.relPath) FROM file f WHERE f.assetId = a.id ORDER BY f.root, f.relPath LIMIT 1) AS rel,
                       (SELECT f.size FROM file f WHERE f.assetId = a.id ORDER BY f.root, f.relPath LIMIT 1) AS size,
                       (SELECT m.relPath FROM motion m WHERE m.assetId = a.id) AS motionRel,
                       (SELECT m.size FROM motion m WHERE m.assetId = a.id) AS motionSize,
                       (a.dateSource = 'photos' OR EXISTS (SELECT 1 FROM meta_edit me WHERE me.assetId = a.id)) AS dated,
                       (SELECT vt.start FROM video_trim vt WHERE vt.assetId = a.id) AS trimStart,
                       (SELECT vt."end" FROM video_trim vt WHERE vt.assetId = a.id) AS trimEnd
                FROM asset a
                WHERE a.id IN (SELECT value FROM json_each(?)) AND a.missingSince IS NULL
                  AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id)
                """, arguments: [json]) {
                let id: String = r["id"]
                guard let rel: String = r["rel"] else { continue }
                let name = (rel as NSString).lastPathComponent
                let ts: Double? = r["trimStart"], te: Double? = r["trimEnd"]
                let info = ExportInfo(
                    title: name, takenAt: r["takenAt"], tzOffset: r["tzOffset"], lat: r["lat"], lon: r["lon"],
                    description: r["description"], favorite: r["favorite"],
                    people: (people[id] ?? []).map { (name: $0.0, x: $0.1, y: $0.2, w: $0.3, h: $0.4) },
                    albums: albums[id] ?? [], width: r["width"], height: r["height"])
                out[id] = Item(id: id, kind: r["kind"], ev: r["editVersion"], dated: r["dated"],
                               trim: ts.flatMap { s in te.map { (s, $0) } },
                               name: name, motionExt: (r["motionRel"] as String?).map { ($0 as NSString).pathExtension },
                               size: r["size"] ?? 0, motionSize: r["motionSize"] ?? 0, info: info)
            }
            return out
        }
    }

    /// Photos and videos to export, each with the folder it goes in.
    func scope(_ o: ExportOptions) throws -> [(id: String, folder: String)] {
        func sortedByDate(_ ids: [String]) throws -> [String] {
            guard !ids.isEmpty else { return [] }
            let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            return try db.writer.read {
                try String.fetchAll($0, sql: "SELECT id FROM asset WHERE id IN (SELECT value FROM json_each(?)) ORDER BY takenAt, id",
                                    arguments: [json])
            }
        }
        if let albums = o.albums, !albums.isEmpty {
            var out: [(String, String)] = []
            var seen = Set<String>()
            var folderNames = Set<String>()
            for album in albums {
                guard let title = try db.writer.read({ try String.fetchOne($0, sql: "SELECT title FROM album WHERE id = ?", arguments: [album]) })
                else { continue }
                let members = try db.writer.read {
                    try String.fetchAll($0, sql: "SELECT assetId FROM album_asset WHERE albumId = ?", arguments: [album])
                }
                var folder = ""
                if o.organize == .albums {
                    folder = Self.unique(Self.safe(title), in: &folderNames)
                }
                for id in try sortedByDate(members) where o.organize == .albums || seen.insert(id).inserted {
                    out.append((id, folder))
                }
            }
            return out
        }
        let ids: [String]
        if o.library == true {
            ids = try db.writer.read {
                try String.fetchAll($0, sql: """
                    SELECT a.id FROM asset a WHERE a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id)
                      AND EXISTS (SELECT 1 FROM file f WHERE f.assetId = a.id)
                    ORDER BY a.takenAt, a.id
                    """)
            }
        } else {
            var seen = Set<String>()
            ids = (o.ids ?? []).filter { seen.insert($0).inserted }
        }
        return ids.map { ($0, "") }
    }

    /// The export's files, in order. Names keep the originals' (made unique per folder).
    public func plan(_ o: ExportOptions) throws -> [ExportEntry] {
        let scoped = try scope(o)
        let items = try items(scoped.map(\.id))
        var entries: [ExportEntry] = []
        var bases: [String: Set<String>] = [:]   // per folder, lowercased base names taken
        for (id, albumFolder) in scoped {
            guard let it = items[id] else { continue }
            var folder = albumFolder
            if o.organize == .months || o.organize == .years {
                let y = ExportStamp.format(it.info.takenAt, tz: it.info.tzOffset, "yyyy")
                let m = ExportStamp.format(it.info.takenAt, tz: it.info.tzOffset, "yyyy-MM")
                folder = o.organize == .years ? y : "\(y)/\(m)"
            }
            let ext = (it.name as NSString).pathExtension
            var base = Self.unique((it.name as NSString).deletingPathExtension, in: &bases[folder, default: []])
            if base.isEmpty { base = id.prefix(12).description }
            let prefix = folder.isEmpty ? "" : folder + "/"
            let date = it.info.takenAt
            let useEdited = o.content != .original && it.edited

            // the photo or video
            var mediaName = base + (ext.isEmpty ? "" : "." + ext)
            var forceXMP = false
            if useEdited {
                if it.kind == "photo" && it.ev > 0 {
                    mediaName = base + (o.format == .heic ? ".heic" : ".jpg")
                    entries.append(ExportEntry(path: prefix + mediaName, source: .edited(assetId: id), modified: date, bytes: it.size))
                } else if it.kind == "photo", let src = try catalog.originals.original(id: id), !MetadataRewriter.supports(src) {
                    // a format whose date can't be rewritten (RAW…): the original, the date in an XMP sidecar
                    entries.append(ExportEntry(path: prefix + mediaName, source: .original(assetId: id), modified: date, bytes: it.size))
                    forceXMP = it.dated
                } else {
                    entries.append(ExportEntry(path: prefix + mediaName, source: .edited(assetId: id), modified: date, bytes: it.size))
                }
            } else {
                entries.append(ExportEntry(path: prefix + mediaName, source: .original(assetId: id), modified: date, bytes: it.size))
            }
            // the Live Photo's video
            var motionName: String?
            if o.livePhotoVideo, it.kind == "photo", let mext = it.motionExt {
                motionName = base + "." + mext.uppercased()
                entries.append(ExportEntry(path: prefix + motionName!, source: .motion(assetId: id, dated: useEdited && it.dated),
                                           modified: date, bytes: it.motionSize))
            }
            // sidecars
            var info = it.info
            info.title = mediaName
            if o.sidecar == .google {
                entries.append(ExportEntry(path: prefix + mediaName + ".supplemental-metadata.json", source: .data(SidecarWriter.google(info)),
                                           modified: date))
                if let motionName {
                    var m = info
                    m.title = motionName
                    entries.append(ExportEntry(path: prefix + motionName + ".supplemental-metadata.json", source: .data(SidecarWriter.google(m)),
                                               modified: date))
                }
            } else if o.sidecar == .xmp || forceXMP {
                entries.append(ExportEntry(path: prefix + base + ".xmp", source: .data(SidecarWriter.xmp(info)), modified: date))
            }
            // the originals of edited items
            if o.content == .both && it.edited {
                let oprefix = "Originals/" + prefix
                entries.append(ExportEntry(path: oprefix + base + (ext.isEmpty ? "" : "." + ext), source: .original(assetId: id),
                                           modified: date, bytes: it.size))
                if o.livePhotoVideo, it.kind == "photo", let mext = it.motionExt, it.dated {
                    entries.append(ExportEntry(path: oprefix + base + "." + mext.uppercased(), source: .motion(assetId: id, dated: false),
                                               modified: date, bytes: it.motionSize))
                }
            }
        }
        if entries.isEmpty { throw ExportError.empty }
        return entries
    }

    /// A name not yet taken in `taken` (case-insensitive): "name", "name (2)"…
    static func unique(_ name: String, in taken: inout Set<String>) -> String {
        var candidate = name
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) (\(n))"
            n += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// A folder name from an album title (no slashes, colons or leading dots).
    static func safe(_ title: String) -> String {
        var s = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Album" : s
    }

    // MARK: Making the files

    /// The file for an entry: a URL on disk, and whether it is a temporary file to delete afterwards.
    public func resolve(_ entry: ExportEntry, format: ImageFormat) async throws -> (url: URL, temporary: Bool)? {
        switch entry.source {
        case .data:
            return nil
        case .original(let id):
            guard let url = try catalog.originals.original(id: id) else { throw ExportError.missing(entry.path) }
            return (url, false)
        case .motion(let id, let dated):
            guard let url = try catalog.originals.motion(id: id) else { throw ExportError.missing(entry.path) }
            guard dated, let a = try catalog.record(id: id) else { return (url, false) }
            let out = try tempURL(ext: url.pathExtension)
            try await VideoCutter.cut(source: url, end: nil, to: out, creationDate: a.takenAt, tzOffset: a.tzOffset, ffmpeg: ffmpeg)
            return (out, true)
        case .edited(let id):
            guard let f = try await editedFile(id: id, format: format) else {
                guard let url = try catalog.originals.original(id: id) else { throw ExportError.missing(entry.path) }
                return (url, false)
            }
            return (f.url, f.temporary)
        }
    }

    /// A photo or video with its edits applied, or nil when it has none: pixel edits rendered at full
    /// size; an adjusted date written into a copy without re-encoding; a trim cut without re-encoding.
    public func editedFile(id: String, format: ImageFormat) async throws -> (url: URL, name: String, temporary: Bool)? {
        guard let a = try catalog.record(id: id), let source = try catalog.originals.original(id: id) else { throw EditError.sourceUnavailable }
        let dated = a.writesDateOnExport
        if a.kind == "video" {
            let trim = try VideoTrimService(db: db).trim(id: id)
            guard trim != nil || dated else { return nil }
            let out = try tempURL(ext: source.pathExtension)
            try await VideoCutter.cut(source: source, start: trim?.start ?? 0, end: trim?.end, to: out,
                                      creationDate: dated ? a.takenAt.addingTimeInterval(trim?.start ?? 0) : nil,
                                      tzOffset: a.tzOffset, ffmpeg: ffmpeg)
            return (out, source.lastPathComponent, true)
        }
        if a.editVersion > 0 {
            let (url, name) = try edits.export(id: id, format: format)
            return (url, name, false)
        }
        guard dated else { return nil }
        let out = try tempURL(ext: source.pathExtension)
        guard MetadataRewriter.rewrite(source: source, to: out, takenAt: a.takenAt, tzOffset: a.tzOffset) else { return nil }
        return (out, source.lastPathComponent, true)
    }

    func tempURL(ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        return workDir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }

    /// Runs an export: each entry's file goes to `write` (a ZIP stream or a folder), in order. A file
    /// that isn't available (moved or deleted since the last scan) is skipped, not fatal: `skipped` hears
    /// of it, and the export ends with an "Export problems.txt" listing them. `alreadyThere` lets a
    /// folder export pick up where an earlier run stopped.
    public func run(_ entries: [ExportEntry], format: ImageFormat,
                    write: (ExportEntry, URL?, Data?) async throws -> Void,
                    progress: (Int) -> Void, isCancelled: () -> Bool,
                    skipped: (String) -> Void = { _ in },
                    alreadyThere: (ExportEntry) -> Bool = { _ in false }) async throws {
        var problems: [String] = []
        for (i, e) in entries.enumerated() {
            if isCancelled() { throw ExportError.cancelled }
            if alreadyThere(e) {
                progress(i + 1)
                continue
            }
            if case .data(let data) = e.source {
                try await write(e, nil, data)
            } else {
                let f: (url: URL, temporary: Bool)?
                do { f = try await resolve(e, format: format) } catch let error where Self.isMissing(error) {
                    problems.append(e.path)
                    skipped(e.path)
                    progress(i + 1)
                    continue
                }
                if let f {
                    defer { if f.temporary { try? FileManager.default.removeItem(at: f.url) } }
                    try await write(e, f.url, nil)
                }
            }
            progress(i + 1)
        }
        if !problems.isEmpty {
            let text = "These files weren't available (moved or deleted since the last scan) and aren't in this export:\n\n"
                + problems.joined(separator: "\n") + "\n"
            let report = ExportEntry(path: Self.problemsFile, source: .data(Data(text.utf8)), modified: Date())
            try await write(report, nil, Data(text.utf8))
        }
    }

    public static let problemsFile = "Export problems.txt"

    /// A file that's gone, as opposed to a failure that should stop the export.
    public static func isMissing(_ error: Error) -> Bool {
        if case ExportError.missing = error { return true }
        if case EditError.sourceUnavailable = error { return true }
        return false
    }

    /// Files of an earlier run into the same folder: there with this entry's date (set when it was
    /// written), and, for files copied as they are, its size. Unfinished files are only ever `.partial`.
    public static func alreadyInFolder(_ root: URL) -> @Sendable (ExportEntry) -> Bool {
        { entry in
            let path = root.appendingPathComponent(entry.path).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, abs(mtime.timeIntervalSince(entry.modified)) < 2 else { return false }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            switch entry.source {
            case .original, .motion(_, false), .data: return size == entry.bytes
            case .edited, .motion(_, true): return size > 0
            }
        }
    }

    /// Writes each file into `root` (folders as in its path): first as "name.partial", renamed when
    /// complete, so an interrupted export never leaves a cut-off file under the real name.
    public static func writeToFolder(_ root: URL) -> (ExportEntry, URL?, Data?) async throws -> Void {
        { entry, url, data in
            let fm = FileManager.default
            let target = root.appendingPathComponent(entry.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var final = target
            var n = 2
            while fm.fileExists(atPath: final.path) {
                let base = (target.lastPathComponent as NSString).deletingPathExtension
                let ext = target.pathExtension
                final = target.deletingLastPathComponent().appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
                n += 1
            }
            let partial = final.deletingLastPathComponent().appendingPathComponent(final.lastPathComponent + ".partial")
            try? fm.removeItem(at: partial)
            if let url { try fm.copyItem(at: url, to: partial) } else if let data { try data.write(to: partial) }
            try? fm.setAttributes([.modificationDate: entry.modified, .creationDate: entry.modified], ofItemAtPath: partial.path)
            try fm.moveItem(at: partial, to: final)
        }
    }
}
