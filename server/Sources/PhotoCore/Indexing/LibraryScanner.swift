import Foundation
import GRDB

public struct ScanReport: Codable, Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    public var unchanged = 0
    public var skipped = 0
    public var errors: [String] = []
}

public enum ScanError: Error, Equatable, CustomStringConvertible {
    case rootUnreadable(String)
    case cancelled

    public var description: String {
        switch self {
        case .rootUnreadable(let p): "Library folder is not readable: \(p). Check that it exists and that PhotoServer has Full Disk Access."
        case .cancelled: "Cancelled"
        }
    }
}

/// Walks the (read-only) library folder and reconciles it with the database.
public final class LibraryScanner: @unchecked Sendable {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "heic", "heif", "hif", "png", "tif", "tiff", "webp", "gif", "bmp", "avif",
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq", "x3f",
    ]

    let db: AppDatabase
    let root: URL
    let serverTZ: TimeZone
    let hasher: (URL) throws -> String

    public init(db: AppDatabase, root: URL, serverTZ: TimeZone = .current,
                hasher: @escaping (URL) throws -> String = FileHasher.sha256) {
        self.db = db
        self.root = root.standardizedFileURL
        self.serverTZ = serverTZ
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
        let (dirs, candidates) = try walk()
        var report = ScanReport()
        let folderIds = try ensureFolders(dirs)
        var existing: [String: FileRow] = [:]
        for row in try db.writer.read({ try FileRow.fetchAll($0) }) { existing[row.relPath] = row }
        var dirEntries: [String: Set<String>] = [:]
        var seen = Set<String>()

        for (i, c) in candidates.enumerated() {
            if isCancelled() { throw ScanError.cancelled }
            progress(i, candidates.count)
            seen.insert(c.relPath)
            let old = existing[c.relPath]
            if let old, old.size == c.size, old.mtime == c.mtime {
                report.unchanged += 1
                continue
            }
            guard let probe = ImageProbe.probe(url: c.url) else {
                report.skipped += 1
                report.errors.append("Unreadable image: \(c.relPath)")
                continue
            }
            let id: String
            do { id = try hasher(c.url) } catch {
                report.skipped += 1
                report.errors.append("Cannot read \(c.relPath): \(error.localizedDescription)")
                continue
            }
            let dirRel = parentRel(c.relPath)
            let sidecarRel = sidecarPath(for: c, dirRel: dirRel, cache: &dirEntries)
            let sidecar = sidecarRel.flatMap { try? Data(contentsOf: root.appendingPathComponent($0)) }.flatMap(SidecarParser.parse)
            let meta = MetadataResolver.resolve(probe: probe, sidecar: sidecar,
                                                fileMTime: Date(timeIntervalSince1970: c.mtime), serverTZ: serverTZ)
            let folderId = folderIds[dirRel]!

            try db.writer.write { d in
                try self.upsertAsset(d, id: id, probe: probe, meta: meta)
                if var row = old {
                    let previous = row.assetId
                    row.assetId = id; row.size = c.size; row.mtime = c.mtime; row.sidecarRelPath = sidecarRel; row.folderId = folderId
                    try row.update(d)
                    if previous != id { try self.relink(d, from: previous, to: id) }
                    try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
                } else {
                    var row = FileRow(id: nil, assetId: id, relPath: c.relPath, folderId: folderId, size: c.size,
                                      mtime: c.mtime, sidecarRelPath: sidecarRel)
                    try row.insert(d)
                    try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
                }
            }
            if old == nil { report.added += 1 } else { report.updated += 1 }
        }
        progress(candidates.count, candidates.count)

        // Files that disappeared.
        let gone = existing.values.filter { !seen.contains($0.relPath) }
        if !gone.isEmpty {
            try db.writer.write { d in
                for row in gone {
                    try row.delete(d)
                    try self.markMissingIfOrphaned(d, assetId: row.assetId)
                }
            }
            report.removed = gone.count
        }
        try pruneEmptyFolders(keeping: Set(dirs))
        return report
    }

    // MARK: - Re-index

    /// Re-reads metadata (sidecar / EXIF / file date) for every file without rehashing.
    public func reindex(progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> ScanReport {
        guard FileManager.default.isReadableFile(atPath: root.path) else { throw ScanError.rootUnreadable(root.path) }
        let rows = try db.writer.read { try FileRow.order(Column("relPath")).fetchAll($0) }
        var report = ScanReport()
        var done = Set<String>()
        var dirEntries: [String: Set<String>] = [:]
        for (i, row) in rows.enumerated() {
            if isCancelled() { throw ScanError.cancelled }
            progress(i, rows.count)
            guard !done.contains(row.assetId) else { continue }
            let url = root.appendingPathComponent(row.relPath)
            guard let probe = ImageProbe.probe(url: url),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                report.skipped += 1
                report.errors.append("Unreadable image: \(row.relPath)")
                continue
            }
            done.insert(row.assetId)
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? row.mtime
            let c = Candidate(relPath: row.relPath, url: url, size: row.size, mtime: mtime)
            let sidecarRel = sidecarPath(for: c, dirRel: parentRel(row.relPath), cache: &dirEntries)
            let sidecar = sidecarRel.flatMap { try? Data(contentsOf: root.appendingPathComponent($0)) }.flatMap(SidecarParser.parse)
            let meta = MetadataResolver.resolve(probe: probe, sidecar: sidecar, fileMTime: Date(timeIntervalSince1970: mtime), serverTZ: serverTZ)
            try db.writer.write { d in
                var r = row
                r.sidecarRelPath = sidecarRel
                try r.update(d)
                try self.applyMetadata(d, id: row.assetId, probe: probe, meta: meta)
                try ChangeLog.record(d, entity: "asset", id: row.assetId, op: "upsert")
            }
            report.updated += 1
        }
        progress(rows.count, rows.count)
        return report
    }

    // MARK: - Helpers

    func walk() throws -> (dirs: [String], files: [Candidate]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              (try? fm.contentsOfDirectory(atPath: root.path)) != nil else {
            throw ScanError.rootUnreadable(root.path)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw ScanError.rootUnreadable(root.path)
        }
        var dirs = [""]
        var files: [Candidate] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in e {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let rel = String(path.dropFirst(prefix.count))
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                dirs.append(rel)
            } else if v.isRegularFile == true, Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                files.append(Candidate(relPath: rel, url: url, size: Int64(v.fileSize ?? 0),
                                       mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        files.sort { $0.relPath < $1.relPath }
        return (dirs, files)
    }

    func parentRel(_ rel: String) -> String {
        guard let slash = rel.lastIndex(of: "/") else { return "" }
        return String(rel[..<slash])
    }

    func ensureFolders(_ dirs: [String]) throws -> [String: Int64] {
        try db.writer.write { d in
            var ids: [String: Int64] = [:]
            for row in try Folder.fetchAll(d) { ids[row.relPath] = row.id }
            for rel in dirs.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count || ($0.split(separator: "/").count == $1.split(separator: "/").count && $0 < $1) }) where ids[rel] == nil {
                let parent = rel.isEmpty ? nil : ids[parentRel(rel)]
                let name = rel.isEmpty ? "" : String(rel.split(separator: "/").last!)
                var f = Folder(id: nil, relPath: rel, parentId: parent, name: name)
                try f.insert(d)
                ids[rel] = f.id
                try ChangeLog.record(d, entity: "folder", id: String(f.id!), op: "upsert")
            }
            return ids
        }
    }

    func pruneEmptyFolders(keeping dirs: Set<String>) throws {
        try db.writer.write { d in
            let stale = try Folder.fetchAll(d).filter { !dirs.contains($0.relPath) }
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

    func upsertAsset(_ d: Database, id: String, probe: ProbeResult, meta: ResolvedMetadata) throws {
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
    func applyMetadata(_ d: Database, id: String, probe: ProbeResult, meta: ResolvedMetadata) throws {
        guard var a = try Asset.fetchOne(d, key: id) else { return }
        a.width = probe.width; a.height = probe.height; a.mime = probe.mime
        a.takenAt = meta.takenAt; a.tzOffset = meta.tzOffset; a.dateSource = meta.dateSource
        a.lat = meta.lat; a.lon = meta.lon; a.locationSource = meta.locationSource
        a.cameraMake = probe.make; a.cameraModel = probe.model; a.lens = probe.lens
        a.iso = probe.iso; a.aperture = probe.aperture; a.shutter = probe.shutter; a.focal = probe.focal
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
        if new.editVersion == 0 { new.editVersion = old.editVersion }
        try new.update(d)
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
