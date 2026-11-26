import Foundation
import GRDB
import UniformTypeIdentifiers

public struct ScanReport: Codable, Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    public var unchanged = 0
    public var skipped = 0
    public var skippedOther = 0
    /// Live Photo motion clips attached (or re-attached) to their still in this run.
    public var liveMotion = 0
    public var errors: [String] = []

    mutating func merge(_ o: ScanReport) {
        added += o.added; updated += o.updated; removed += o.removed; unchanged += o.unchanged
        skipped += o.skipped; skippedOther += o.skippedOther; liveMotion += o.liveMotion; errors += o.errors
    }
}

final class FailedDirs: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var paths: [String] = []
    func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
}

public enum Roots {
    public static let library = "library"
    public static let uploads = "uploads"
}

public enum ScanError: Error, Equatable, CustomStringConvertible {
    case rootUnreadable(String)
    case cancelled
    case notAnImage(String)

    public var description: String {
        switch self {
        case .rootUnreadable(let p): "Library folder is not readable: \(p). Check that it exists and that PhotoServer has Full Disk Access."
        case .cancelled: "Cancelled"
        case .notAnImage(let why): why
        }
    }
}

/// Walks the (read-only) library folder and reconciles it with the database.
public final class LibraryScanner: @unchecked Sendable {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "heic", "heif", "hif", "png", "tif", "tiff", "webp", "gif", "bmp", "avif",
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq", "x3f",
    ]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm"]

    let db: AppDatabase
    let root: URL
    /// Which root this scanner owns rows for ("library" or "uploads").
    let rootName: String
    let serverTZ: TimeZone
    let hasher: (URL) throws -> String
    /// Directories never indexed (e.g. the app's own data folder if it sits under the library).
    let excluding: [String]

    public init(db: AppDatabase, root: URL, rootName: String = Roots.library, serverTZ: TimeZone = .current,
                excluding: [URL] = [], hasher: @escaping (URL) throws -> String = FileHasher.sha256) {
        self.db = db
        self.root = root.standardizedFileURL
        self.rootName = rootName
        self.serverTZ = serverTZ
        self.excluding = excluding.map { PathOverlap.normalized($0.path) }
        self.hasher = hasher
    }

    struct Candidate {
        let relPath: String
        let url: URL
        let size: Int64
        let mtime: Double
    }

    // MARK: - Detect changes

    public func detectChanges(progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> ScanReport {
        let (dirs, images, videos, failedDirs, others) = try walk(isCancelled: isCancelled)
        var report = ScanReport()
        report.skippedOther = others
        let folderIds = try ensureFolders(dirs)
        var existing: [String: FileRow] = [:]
        for row in try db.writer.read({ try FileRow.filter(Column("root") == rootName).fetchAll($0) }) { existing[row.relPath] = row }
        let probeVersions = try db.writer.read { d in
            Dictionary(try Row.fetchAll(d, sql: "SELECT id, probeVersion FROM asset").map { ($0["id"] as String, $0["probeVersion"] as Int) },
                       uniquingKeysWith: { a, _ in a })
        }
        var dirEntries: [String: Set<String>] = [:]
        var reprobed = Set<String>()
        let total = images.count + videos.count

        // 1. Images: new or changed files are hashed; unchanged ones probed by an older scanner are re-read.
        for (i, c) in images.enumerated() {
            if isCancelled() { throw ScanError.cancelled }
            progress(i, total)
            let old = existing[c.relPath]
            if let old, old.size == c.size, old.mtime == c.mtime {
                if (probeVersions[old.assetId] ?? Asset.currentProbeVersion) < Asset.currentProbeVersion,
                   reprobed.insert(old.assetId).inserted {
                    if try refreshMetadata(old, url: c.url, mtime: c.mtime, dirEntries: &dirEntries) {
                        report.updated += 1
                    } else {
                        report.skipped += 1
                        report.errors.append("Unreadable image: \(c.relPath)")
                    }
                } else {
                    report.unchanged += 1
                }
                continue
            }
            switch try indexCandidate(c, old: old, folderId: folderIds[parentRel(c.relPath)]!, dirEntries: &dirEntries) {
            case .indexed:
                if old == nil { report.added += 1 } else { report.updated += 1 }
            case .skipped(let why):
                report.skipped += 1
                report.errors.append(why)
            }
        }

        // 2. Files that disappeared — but never those under folders we failed to read.
        for d in failedDirs { report.errors.append("Could not read folder \(d.isEmpty ? "(\(rootName) root)" : d); its photos were left untouched.") }
        // Also keeps the uploads Trash (a hidden folder scans don't list): those photos aren't gone.
        func underFailedDir(_ rel: String) -> Bool {
            rel.hasPrefix(UploadTrash.dirName + "/") || failedDirs.contains { d in d.isEmpty || rel.hasPrefix(d + "/") }
        }
        let seen = Set(images.map(\.relPath)).union(videos.map(\.relPath))
        let gone = existing.values.filter { !seen.contains($0.relPath) && !underFailedDir($0.relPath) }
        if !gone.isEmpty {
            try db.writer.write { d in
                for row in gone {
                    try row.delete(d)
                    try self.markMissingIfOrphaned(d, assetId: row.assetId)
                }
            }
            report.removed += gone.count
        }
        try removeVanishedMotion(present: Set(videos.map(\.relPath)), keep: underFailedDir)

        // 3. Videos: Live Photo motion clips attach to their still; the rest become video assets.
        try indexVideos(videos, existing: existing, probeVersions: probeVersions, folderIds: folderIds,
                        dirEntries: &dirEntries, report: &report) { i in
            if isCancelled() { throw ScanError.cancelled }
            progress(images.count + i, total)
        }
        progress(total, total)

        try pruneEmptyFolders(keeping: Set(dirs).union(failedDirs))
        return report
    }

    enum IndexOutcome { case indexed(String), skipped(String) }

    /// Probes, hashes and records one file (new or changed). Shared by scans and uploads.
    /// `video` passes an already-probed video so it isn't probed twice.
    func indexCandidate(_ c: Candidate, old: FileRow?, folderId: Int64, dirEntries: inout [String: Set<String>],
                        video: VideoProbeResult? = nil) throws -> IndexOutcome {
        let probe: MediaProbe
        if let video {
            probe = .video(video, ext: c.url.pathExtension.lowercased())
        } else if let p = MediaProbe.probe(url: c.url) {
            probe = p
        } else {
            return .skipped("\(MediaProbe.isVideo(c.url) ? "Unreadable video" : "Unreadable image"): \(c.relPath)")
        }
        let id: String
        do { id = try hasher(c.url) } catch {
            return .skipped("Cannot read \(c.relPath): \(error.localizedDescription)")
        }
        let sidecarRel = sidecarPath(for: c, dirRel: parentRel(c.relPath), cache: &dirEntries)
        let meta = resolve(probe, sidecarRel: sidecarRel, mtime: c.mtime)
        try db.writer.write { d in
            try self.upsertAsset(d, id: id, probe: probe, meta: meta)
            if var row = old {
                let previous = row.assetId
                row.assetId = id; row.size = c.size; row.mtime = c.mtime; row.sidecarRelPath = sidecarRel; row.folderId = folderId
                try row.update(d)
                if previous != id { try self.relink(d, from: previous, to: id) }
            } else {
                var row = FileRow(id: nil, assetId: id, relPath: c.relPath, folderId: folderId, size: c.size,
                                  mtime: c.mtime, sidecarRelPath: sidecarRel, root: self.rootName)
                try row.insert(d)
            }
            try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
        }
        return .indexed(id)
    }

    /// Indexes a single file inside this root (used right after an upload). Returns the asset id.
    public func indexFile(relPath: String) throws -> String {
        let url = root.appendingPathComponent(relPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let c = Candidate(relPath: relPath, url: url, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                          mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        var dirs = [""]
        var acc = ""
        for part in parentRel(relPath).split(separator: "/") {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            dirs.append(acc)
        }
        let folderIds = try ensureFolders(dirs)
        let old = try db.writer.read { try FileRow.filter(Column("root") == rootName && Column("relPath") == relPath).fetchOne($0) }
        var entries: [String: Set<String>] = [:]
        switch try indexCandidate(c, old: old, folderId: folderIds[parentRel(relPath)]!, dirEntries: &entries) {
        case .indexed(let id): return id
        case .skipped(let why): throw ScanError.notAnImage(why)
        }
    }

    // MARK: - Re-index

    /// Re-reads metadata (sidecar / EXIF / file date) for every file without rehashing.
    public func reindex(progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> ScanReport {
        guard FileManager.default.isReadableFile(atPath: root.path) else { throw ScanError.rootUnreadable(root.path) }
        let rows = try db.writer.read { try FileRow.filter(Column("root") == rootName).order(Column("relPath")).fetchAll($0) }
        var report = ScanReport()
        var done = Set<String>()
        var dirEntries: [String: Set<String>] = [:]
        for (i, row) in rows.enumerated() {
            if isCancelled() { throw ScanError.cancelled }
            progress(i, rows.count)
            guard !done.contains(row.assetId) else { continue }
            let url = root.appendingPathComponent(row.relPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                report.skipped += 1
                report.errors.append("File not found: \(row.relPath)")
                continue
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? row.mtime
            guard attrs != nil, try refreshMetadata(row, url: url, mtime: mtime, dirEntries: &dirEntries) else {
                report.skipped += 1
                report.errors.append("\(MediaProbe.isVideo(url) ? "Unreadable video" : "Unreadable image"): \(row.relPath)")
                continue
            }
            done.insert(row.assetId)
            report.updated += 1
        }
        try refreshMotion(isCancelled: isCancelled)
        progress(rows.count, rows.count)
        return report
    }

    /// Re-probes one file and rewrites its machine-derived metadata, without rehashing. False when unreadable.
    func refreshMetadata(_ row: FileRow, url: URL, mtime: Double, dirEntries: inout [String: Set<String>]) throws -> Bool {
        guard let probe = MediaProbe.probe(url: url) else { return false }
        let c = Candidate(relPath: row.relPath, url: url, size: row.size, mtime: mtime)
        let sidecarRel = sidecarPath(for: c, dirRel: parentRel(row.relPath), cache: &dirEntries)
        let meta = resolve(probe, sidecarRel: sidecarRel, mtime: mtime)
        try db.writer.write { d in
            var r = row
            r.sidecarRelPath = sidecarRel
            try r.update(d)
            try self.applyMetadata(d, id: row.assetId, probe: probe, meta: meta)
            try ChangeLog.record(d, entity: "asset", id: row.assetId, op: "upsert")
        }
        return true
    }

    func resolve(_ probe: MediaProbe, sidecarRel: String?, mtime: Double) -> ResolvedMetadata {
        let sidecar = sidecarRel.flatMap { try? Data(contentsOf: root.appendingPathComponent($0)) }.flatMap(SidecarParser.parse)
        let date = Date(timeIntervalSince1970: mtime)
        switch probe {
        case .image(let p): return MetadataResolver.resolve(probe: p, sidecar: sidecar, fileMTime: date, serverTZ: serverTZ)
        case .video(let v, _): return MetadataResolver.resolve(video: v, sidecar: sidecar, fileMTime: date, serverTZ: serverTZ)
        }
    }

    // MARK: - Helpers

    func walk(isCancelled: () -> Bool = { false }) throws
        -> (dirs: [String], images: [Candidate], videos: [Candidate], failed: [String], others: Int) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              (try? fm.contentsOfDirectory(atPath: root.path)) != nil else {
            throw ScanError.rootUnreadable(root.path)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var failed: [String] = []
        let errorBox = FailedDirs()
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                    errorHandler: { url, _ in errorBox.add(url.standardizedFileURL.path); return true }) else {
            throw ScanError.rootUnreadable(root.path)
        }
        var dirs = [""]
        var files: [Candidate] = []
        var videos: [Candidate] = []
        var others = 0
        var visited = 0
        for case let url as URL in e {
            visited += 1
            if visited % 500 == 1, isCancelled() { throw ScanError.cancelled }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let rel = String(path.dropFirst(prefix.count))
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if excluding.contains(PathOverlap.normalized(path)) {
                    e.skipDescendants()
                    continue
                }
                // A directory we can see but not list: keep its rows, report it.
                if (try? fm.contentsOfDirectory(atPath: path)) == nil {
                    failed.append(rel)
                    e.skipDescendants()
                }
                dirs.append(rel)
            } else if v.isRegularFile == true {
                let ext = url.pathExtension.lowercased()
                let c = Candidate(relPath: rel, url: url, size: Int64(v.fileSize ?? 0),
                                  mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                if Self.imageExtensions.contains(ext) {
                    files.append(c)
                } else if Self.videoExtensions.contains(ext) {
                    videos.append(c)
                } else if ext != "json" {
                    others += 1
                }
            }
        }
        for p in errorBox.paths where p.hasPrefix(prefix) {
            let rel = String(p.dropFirst(prefix.count))
            if !failed.contains(rel) { failed.append(rel) }
        }
        files.sort { $0.relPath < $1.relPath }
        videos.sort { $0.relPath < $1.relPath }
        return (dirs, files, videos, failed, others)
    }

    func parentRel(_ rel: String) -> String {
        guard let slash = rel.lastIndex(of: "/") else { return "" }
        return String(rel[..<slash])
    }

    func ensureFolders(_ dirs: [String]) throws -> [String: Int64] {
        try db.writer.write { d in
            var ids: [String: Int64] = [:]
            for row in try Folder.filter(Column("root") == rootName).fetchAll(d) { ids[row.relPath] = row.id }
            for rel in dirs.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count || ($0.split(separator: "/").count == $1.split(separator: "/").count && $0 < $1) }) where ids[rel] == nil {
                let parent = rel.isEmpty ? nil : ids[parentRel(rel)]
                let name = rel.isEmpty ? "" : String(rel.split(separator: "/").last!)
                var f = Folder(id: nil, relPath: rel, parentId: parent, name: name, root: rootName)
                try f.insert(d)
                ids[rel] = f.id
                try ChangeLog.record(d, entity: "folder", id: String(f.id!), op: "upsert")
            }
            return ids
        }
    }

    func pruneEmptyFolders(keeping dirs: Set<String>) throws {
        try db.writer.write { d in
            let stale = try Folder.filter(Column("root") == rootName).fetchAll(d).filter { !dirs.contains($0.relPath) }
            for f in stale.sorted(by: { $0.relPath.count > $1.relPath.count }) {
                let count = try FileRow.filter(Column("folderId") == f.id!).fetchCount(d)
                if count == 0 {
                    try f.delete(d)
                    try ChangeLog.record(d, entity: "folder", id: String(f.id!), op: "delete")
                }
            }
        }
    }

    func sidecarPath(for c: Candidate, dirRel: String, cache: inout [String: Set<String>]) -> String? {
        if cache[dirRel] == nil {
            let dirURL = dirRel.isEmpty ? root : root.appendingPathComponent(dirRel)
            cache[dirRel] = Set((try? FileManager.default.contentsOfDirectory(atPath: dirURL.path)) ?? [])
        }
        let name = (c.relPath as NSString).lastPathComponent
        guard let hit = SidecarLocator.sidecar(for: name, in: cache[dirRel]!) else { return nil }
        return dirRel.isEmpty ? hit : dirRel + "/" + hit
    }

    func upsertAsset(_ d: Database, id: String, probe: MediaProbe, meta: ResolvedMetadata) throws {
        if var existing = try Asset.fetchOne(d, key: id) {
            if existing.missingSince != nil {
                existing.missingSince = nil
                try existing.update(d)
            }
            return
        }
        var a = Asset.placeholder(id: id)
        a.favorite = meta.favorited ?? false
        a.description = meta.description
        try a.insert(d)
        try applyMetadata(d, id: id, probe: probe, meta: meta)
    }

    /// Writes machine-derived fields; never touches user-set values.
    func applyMetadata(_ d: Database, id: String, probe: MediaProbe, meta: ResolvedMetadata) throws {
        guard var a = try Asset.fetchOne(d, key: id) else { return }
        switch probe {
        case .image(let p):
            a.kind = "photo"
            a.width = p.width; a.height = p.height; a.mime = p.mime
            a.cameraMake = p.make; a.cameraModel = p.model; a.lens = p.lens
            a.iso = p.iso; a.aperture = p.aperture; a.shutter = p.shutter; a.focal = p.focal
            a.contentId = p.contentId
        case .video(let v, let ext):
            a.kind = "video"
            a.width = v.width; a.height = v.height
            a.mime = UTType(filenameExtension: ext)?.identifier ?? UTType.movie.identifier
            a.cameraMake = v.make; a.cameraModel = v.model; a.lens = nil
            a.iso = nil; a.aperture = nil; a.shutter = nil; a.focal = nil
            a.contentId = v.contentId
            a.duration = v.duration; a.videoCodec = v.codec; a.videoHDR = v.hdr
            a.servePlan = VideoProbe.servePlan(codec: v.codec, ext: ext, width: v.width, height: v.height)
            a.videoError = nil
        }
        a.probeVersion = Asset.currentProbeVersion
        a.takenAt = meta.takenAt; a.tzOffset = meta.tzOffset; a.dateSource = meta.dateSource
        a.lat = meta.lat; a.lon = meta.lon; a.locationSource = meta.locationSource
        if !a.favoriteUserSet, let f = meta.favorited { a.favorite = f }
        if a.description == nil { a.description = meta.description }
        try a.update(d)
    }

    /// Content changed at the same path: carry user data from the old asset to the new one.
    func relink(_ d: Database, from oldId: String, to newId: String) throws {
        guard let old = try Asset.fetchOne(d, key: oldId), var new = try Asset.fetchOne(d, key: newId) else { return }
        if old.favoriteUserSet || old.favorite {
            new.favorite = new.favorite || old.favorite
            new.favoriteUserSet = new.favoriteUserSet || old.favoriteUserSet
        }
        if new.description == nil { new.description = old.description }
        try new.update(d)
        try EditService.relink(d, from: oldId, to: newId, sizeChanged: old.width != new.width || old.height != new.height)
        // Albums follow the photo to its new content.
        try ChangeLog.recordAlbums(d, containing: [oldId])
        try d.execute(sql: """
            INSERT OR IGNORE INTO album_asset (albumId, assetId, position)
            SELECT albumId, ?, position FROM album_asset WHERE assetId = ?
            """, arguments: [newId, oldId])
        try d.execute(sql: "DELETE FROM album_asset WHERE assetId = ?", arguments: [oldId])
        try markMissingIfOrphaned(d, assetId: oldId)
    }

    func markMissingIfOrphaned(_ d: Database, assetId: String) throws {
        let remaining = try FileRow.filter(Column("assetId") == assetId).fetchCount(d)
        guard remaining == 0, var a = try Asset.fetchOne(d, key: assetId), a.missingSince == nil else { return }
        a.missingSince = Date()
        try a.update(d)
        try ChangeLog.record(d, entity: "asset", id: assetId, op: "delete")
    }
}
