import Foundation
import GRDB

/// Scans a library folder on an rclone remote. The listing comes from rclone in one call; new and
/// changed photos and videos are fetched into the source's mirror folder on this Mac a batch at a time
/// (a folder at a time, with the folder's sidecars, many files in parallel), indexed there by the
/// same `LibraryScanner` as the folder on this Mac, and their thumbnails and previews made while they
/// are here. Then the originals cache keeps the most recently used within its size.
public final class RemoteScanner: @unchecked Sendable {
    let db: AppDatabase
    let source: RemoteSource
    let mirror: URL
    let rclone: Rclone
    let serverTZ: TimeZone
    let cacheBudget: Int64
    let dataDir: URL
    /// Files per batch, and bytes: whichever comes first (a folder bigger than that is split).
    /// Hears what the scan is doing, in words (listing, downloading which folder, reading it).
    public var status: (@Sendable (String) -> Void)?
    var batchFiles = 400
    var batchBytes: Int64 = 4_000_000_000

    public init(db: AppDatabase, source: RemoteSource, dataDir: URL, rclone: Rclone, serverTZ: TimeZone = .current, cacheBudget: Int64) {
        self.db = db
        self.source = source
        self.dataDir = dataDir
        self.mirror = RemoteSources.mirror(source.root, dataDir: dataDir)
        self.rclone = rclone
        self.serverTZ = serverTZ
        self.cacheBudget = cacheBudget
    }

    /// `render` makes the thumbnails and previews of a batch's photos and videos (asset id, file), while
    /// they're on this Mac.
    public func detectChanges(progress: (Int, Int) -> Void, isCancelled: () -> Bool,
                              render: ([(id: String, url: URL)]) -> Void) throws -> ScanReport {
        let listed: [Rclone.RemoteFile]
        status?("Listing the files in \(source.path)…")
        do { listed = try rclone.files(source.path) } catch {
            throw ScanError.rootUnreadable("\(source.path): \((error as? CustomStringConvertible)?.description ?? error.localizedDescription)")
        }
        if isCancelled() { throw ScanError.cancelled }
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)

        var report = ScanReport()
        var images: [Rclone.RemoteFile] = [], videos: [Rclone.RemoteFile] = []
        var sidecarsByDir: [String: [String]] = [:]
        var dirs = Set([""])
        for f in listed {
            // hidden files and folders are skipped, as in the folder on this Mac
            if f.path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            var parent = Self.parent(f.path)
            while !dirs.contains(parent) {
                dirs.insert(parent)
                parent = Self.parent(parent)
            }
            let ext = (f.path as NSString).pathExtension.lowercased()
            if LibraryScanner.imageExtensions.contains(ext) { images.append(f) }
            else if LibraryScanner.videoExtensions.contains(ext) { videos.append(f) }
            else if ext == "json" || ext == "xmp" { sidecarsByDir[Self.parent(f.path), default: []].append(f.path) }
            else { report.skippedOther += 1 }
        }

        // what's new or changed since the last scan
        let existing = try db.writer.read { d in
            Dictionary(try FileRow.filter(Column("root") == source.root).fetchAll(d).map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let motions = try db.writer.read { d in
            Dictionary(try MotionRow.filter(Column("root") == source.root).fetchAll(d).map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })
        }
        func changed(_ f: Rclone.RemoteFile) -> Bool {
            if let r = existing[f.path] { return r.size != f.size || r.mtime != f.mtime }
            if let m = motions[f.path] { return m.size != f.size || m.mtime != f.mtime }
            return true
        }
        let todo = (images + videos).filter(changed).sorted { $0.path < $1.path }
        report.unchanged = images.count + videos.count - todo.count

        let scanner = LibraryScanner(db: db, root: mirror, rootName: source.root, serverTZ: serverTZ)
        scanner.batch = true
        var done = 0
        progress(0, todo.count)
        for batch in batches(todo) {
            if isCancelled() { throw ScanError.cancelled }
            InteractiveWork.yield()
            // the batch's files, their own sidecars and their folders' metadata.json (only those not here yet)
            let batchDirs = Set(batch.map { Self.parent($0.path) })
            let sidecars = Self.sidecars(for: batch, in: sidecarsByDir).filter {
                !FileManager.default.fileExists(atPath: mirror.appendingPathComponent($0).path)
            }
            let place = Self.describe(batchDirs)
            let mb = Double(batch.reduce(Int64(0)) { $0 + $1.size }) / 1_000_000
            let size = mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : String(format: "%.0f MB", mb)
            let media = Set(batch.map(\.path))
            var arrived = 0, lastShown = Date.distantPast
            func show() {
                status?("Downloading \(place): \(arrived) of \(batch.count) photos and videos (\(size))"
                        + (sidecars.isEmpty ? "" : " and their \(sidecars.count) sidecar files"))
            }
            show()
            do {
                try withoutActuallyEscaping(progress) { progress in
                    try withoutActuallyEscaping(isCancelled) { isCancelled in
                        try rclone.copyFiles(batch.map(\.path) + sidecars, from: source.path, to: mirror.path, isCancelled: isCancelled) { file in
                            guard media.contains(file) else { return }
                            arrived += 1
                            progress(done + arrived, todo.count)
                            if Date().timeIntervalSince(lastShown) > 1 { lastShown = Date(); show() }
                        }
                    }
                }
            } catch RcloneError.cancelled {
                throw ScanError.cancelled
            } catch {
                report.errors.append("Could not fetch \(batchDirs.sorted().first ?? "") from \(source.path): \((error as? CustomStringConvertible)?.description ?? "")")
                done += batch.count
                progress(done, todo.count)
                continue
            }
            func candidate(_ f: Rclone.RemoteFile) -> LibraryScanner.Candidate {
                LibraryScanner.Candidate(relPath: f.path, url: mirror.appendingPathComponent(f.path), size: f.size, mtime: f.mtime)
            }
            var ancestors = Set([""])
            for d in batchDirs {
                var p = d
                while !ancestors.contains(p) { ancestors.insert(p); p = Self.parent(p) }
            }
            let isVideo = { (f: Rclone.RemoteFile) in LibraryScanner.videoExtensions.contains((f.path as NSString).pathExtension.lowercased()) }
            status?("Reading \(place): dates, places and thumbnails of \(batch.count) photos and videos")
            scanner.listing = (Array(ancestors), batch.filter { !isVideo($0) }.map(candidate), batch.filter(isVideo).map(candidate), [], 0)
            let base = done
            let r = try scanner.detectChanges(progress: { i, _ in progress(base + i, todo.count) }, isCancelled: isCancelled)
            report.merge(r)
            report.unchanged -= r.unchanged   // already counted

            // thumbnails and previews while the files are here (Live Photo clips have none)
            let paths = batch.map(\.path)
            let made = try db.writer.read { d in
                try Row.fetchAll(d, sql: """
                    SELECT assetId, relPath FROM file WHERE root = ? AND relPath IN (SELECT value FROM json_each(?))
                    """, arguments: [source.root, String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)])
                    .map { (id: $0["assetId"] as String, url: mirror.appendingPathComponent($0["relPath"] as String)) }
            }
            render(made)
            done += batch.count
            progress(done, todo.count)
            OriginalsCache.evict(dataDir: dataDir, budget: cacheBudget, force: true)
        }
        report.removed += try scanner.finishBatches(present: Set((images + videos).map(\.path)), videos: Set(videos.map(\.path)),
                                                    dirs: Array(dirs))
        try nameRootFolder(scanner)
        return report
    }

    /// The source's top folder is shown with the source's name ("pcloud:Photos/Trips" → "Trips").
    func nameRootFolder(_ scanner: LibraryScanner) throws {
        let id = try scanner.ensureFolders([""])[""]!
        let title = source.title
        try db.writer.write { d in
            guard try String.fetchOne(d, sql: "SELECT name FROM folder WHERE id = ?", arguments: [id]) != title else { return }
            try d.execute(sql: "UPDATE folder SET name = ? WHERE id = ?", arguments: [title, id])
            try ChangeLog.record(d, entity: "folder", id: String(id), op: "upsert")
        }
    }

    /// Whole folders at a time while they fit; a bigger folder is split, never between files of the
    /// same name (a photo and its Live Photo clip).
    func batches(_ files: [Rclone.RemoteFile]) -> [[Rclone.RemoteFile]] {
        var out: [[Rclone.RemoteFile]] = []
        var current: [Rclone.RemoteFile] = []
        var bytes: Int64 = 0
        func stem(_ p: String) -> String { (p as NSString).deletingPathExtension.lowercased() }
        for f in files {
            let full = current.count >= batchFiles || bytes >= batchBytes
            if full, let last = current.last, stem(last.path) != stem(f.path) {
                out.append(current)
                current = []
                bytes = 0
            }
            current.append(f)
            bytes += f.size
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The sidecars a batch needs: each file's own (as the scan will look for it) and the
    /// metadata.json of its folders (Google Takeout album titles). A folder's other sidecars stay
    /// on the remote until their photos are fetched.
    static func sidecars(for batch: [Rclone.RemoteFile], in byDir: [String: [String]]) -> [String] {
        var out = Set<String>()
        var names: [String: Set<String>] = [:]
        for f in batch {
            let dir = parent(f.path)
            if names[dir] == nil { names[dir] = Set((byDir[dir] ?? []).map { ($0 as NSString).lastPathComponent }) }
            let inDir = names[dir]!
            func add(_ name: String) { out.insert(dir.isEmpty ? name : dir + "/" + name) }
            let name = (f.path as NSString).lastPathComponent
            if let json = SidecarLocator.sidecar(for: name, in: inDir) { add(json) }
            let stem = (name as NSString).deletingPathExtension.lowercased()
            for x in inDir where x.lowercased() == stem + ".xmp" || x.lowercased() == name.lowercased() + ".xmp" { add(x) }
            if inDir.contains("metadata.json") { add("metadata.json") }
        }
        return out.sorted()
    }

    /// "Library/Photos from 2001", or "Library/Photos from 2001 and 2 more folders".
    static func describe(_ dirs: Set<String>) -> String {
        let first = dirs.sorted().first.map { $0.isEmpty ? "the top folder" : $0 } ?? ""
        return dirs.count > 1 ? "\(first) and \(dirs.count - 1) more folder\(dirs.count == 2 ? "" : "s")" : first
    }

    static func parent(_ rel: String) -> String {
        guard let slash = rel.lastIndex(of: "/") else { return "" }
        return String(rel[..<slash])
    }
}
