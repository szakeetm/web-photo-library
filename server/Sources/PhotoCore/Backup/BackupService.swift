import Foundation
import GRDB

extension SettingKey where T == Bool {
    /// Back up the database and uploads to `backupDestination` every `backupIntervalHours`.
    public static let backupEnabled = SettingKey("backupEnabled", default: false)
}

extension SettingKey where T == String? {
    /// An rclone path ("remote:folder"); nil = `BackupService.defaultDestination`.
    public static let backupDestination = SettingKey("backupDestination", default: nil)
}

extension SettingKey where T == Int? {
    /// Hours between backups; nil = 24.
    public static let backupIntervalHours = SettingKey("backupIntervalHours", default: nil)
}

extension SettingKey where T == BackupReport? {
    /// How the last backup went.
    public static let lastBackup = SettingKey("lastBackup", default: nil)
}

/// A folder photos come from, as recorded in a backup: restoring checks it's still there.
public struct BackupSource: Codable, Sendable, Equatable {
    /// "library" (the folder on this Mac) or "remote-<n>" (an rclone source)
    public var root: String
    /// "local" (a folder on this Mac) or "rclone" (a remote path)
    public var kind: String
    public var path: String
    public var files: Int
    /// A few of its files (path relative to the source, size), to check they're still where they were.
    public var samples: [Sample]

    public struct Sample: Codable, Sendable, Equatable {
        public var path: String
        public var size: Int64
    }
}

/// What a backup holds: written next to it as manifest.json, after the database and uploads.
public struct BackupManifest: Codable, Sendable, Equatable {
    /// The backup format (`BackupFormat.current` when written): see docs/backup-format.md.
    public var version = BackupFormat.current
    public var createdAt: Date
    public var serverVersion: String
    /// The database's applied migrations: a server that doesn't know one of them can't open it.
    public var migrations: [String]
    public var databaseBytes: Int64
    public var assets: Int
    public var albums: Int
    public var sources: [BackupSource]
    public var uploadsPath: String?
    public var uploadsFiles: Int
    public var uploadsBytes: Int64
}

/// Versions of the backup format, and the changes that broke restoring older backups. Documented in
/// docs/backup-format.md: bump `current` when the layout or the manifest changes; when a change means
/// older backups can't be restored any more, raise `oldestRestorable` and say why in `breaking`.
/// (Database changes don't need either: restored databases are migrated forward, and one from a
/// newer server is refused by its migrations.)
public enum BackupFormat {
    /// written by this server
    public static let current = 1
    /// the oldest this server restores
    public static let oldestRestorable = 1
    /// why backups older than a format can't be restored: format → explanation
    public static let breaking: [Int: String] = [:]

    /// Whether a backup in `format` can be restored here, and why not.
    public static func check(_ format: Int) -> (ok: Bool, detail: String) {
        if format > current {
            return (false, "Backup format \(format) is newer than this server's (\(current)): update the server first.")
        }
        if format < oldestRestorable {
            let why = breaking.filter { $0.key > format }.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ")
            return (false, "Backup format \(format) can't be restored by this server (oldest: \(oldestRestorable)). \(why)")
        }
        return (true, "Format \(format)")
    }
}

/// How a backup went (kept in the settings, shown in Settings).
public struct BackupReport: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var finishedAt: Date
    public var ok: Bool
    public var error: String?
    public var destination: String
    public var databaseBytes: Int64
    public var assets: Int
    public var albums: Int
    public var uploadsFiles: Int
    public var uploadsBytes: Int64
    /// uploads copied this time (new or changed since the previous backup)
    public var uploadsCopied: Int
    /// uploads removed from the backup this time (deleted here since the previous backup)
    public var uploadsDeleted: Int = 0

    public init(startedAt: Date, finishedAt: Date, ok: Bool, error: String? = nil, destination: String, databaseBytes: Int64,
                assets: Int, albums: Int, uploadsFiles: Int, uploadsBytes: Int64, uploadsCopied: Int, uploadsDeleted: Int = 0) {
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.ok = ok; self.error = error; self.destination = destination
        self.databaseBytes = databaseBytes; self.assets = assets; self.albums = albums; self.uploadsFiles = uploadsFiles
        self.uploadsBytes = uploadsBytes; self.uploadsCopied = uploadsCopied; self.uploadsDeleted = uploadsDeleted
    }

    enum CodingKeys: String, CodingKey {
        case startedAt, finishedAt, ok, error, destination, databaseBytes, assets, albums, uploadsFiles, uploadsBytes, uploadsCopied, uploadsDeleted
    }

    /// Reports saved by earlier versions lack the newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decode(Date.self, forKey: .finishedAt)
        ok = try c.decode(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        destination = try c.decode(String.self, forKey: .destination)
        databaseBytes = try c.decodeIfPresent(Int64.self, forKey: .databaseBytes) ?? 0
        assets = try c.decodeIfPresent(Int.self, forKey: .assets) ?? 0
        albums = try c.decodeIfPresent(Int.self, forKey: .albums) ?? 0
        uploadsFiles = try c.decodeIfPresent(Int.self, forKey: .uploadsFiles) ?? 0
        uploadsBytes = try c.decodeIfPresent(Int64.self, forKey: .uploadsBytes) ?? 0
        uploadsCopied = try c.decodeIfPresent(Int.self, forKey: .uploadsCopied) ?? 0
        uploadsDeleted = try c.decodeIfPresent(Int.self, forKey: .uploadsDeleted) ?? 0
    }
}

/// What's happening right now (a backup or a restore).
public struct BackupActivity: Codable, Sendable, Equatable {
    /// "backup" or "restore"
    public var kind: String
    public var phase: String
    public var startedAt: Date
    public var files: Int = 0
}

public enum BackupError: Error, CustomStringConvertible {
    case busy, noUploadsFolder, cannotRestore([String]), newerDatabase, notADatabase
    public var description: String {
        switch self {
        case .busy: "A backup or restore is already running."
        case .noUploadsFolder: "Choose an uploads folder first (Settings → Library): restored uploads go there."
        case .cannotRestore(let p): "Can't restore: " + p.joined(separator: " ")
        case .newerDatabase: "This backup was made by a newer version of the server: update it first."
        case .notADatabase: "The backup's database can't be opened."
        }
    }
}

/// The result of looking at a backup location before restoring from it.
public struct BackupInspection: Codable, Sendable, Equatable {
    public struct Check: Codable, Sendable, Equatable {
        public var title: String
        public var ok: Bool
        public var detail: String
    }
    public var location: String
    public var manifest: BackupManifest?
    /// what's on the remote
    public var databaseBytes: Int64
    public var uploadsFiles: Int
    public var uploadsBytes: Int64
    /// where restored uploads go
    public var uploadsTarget: String?
    public var checks: [Check]
    public var canRestore: Bool
}

/// Backs up what can't be rebuilt — the database (catalog, albums, edits, people…) and the uploads
/// (kept the same as the uploads folder: uploads deleted here are deleted from the backup) —
/// to an rclone destination, and restores it. Caches are left out: they're rebuilt from the
/// originals. The same file names are written each time; a remote that keeps versions (pCloud,
/// S3 with versioning…) keeps the history.
///
/// Layout: `<destination>/library.sqlite`, `<destination>/uploads/…`, `<destination>/manifest.json`
/// (written last: a backup with a manifest is complete).
public final class BackupService: @unchecked Sendable {
    public static let defaultDestination = "pcloud:Photos/webLibrary_backup"
    public static let defaultIntervalHours = 24
    /// After a failed backup, try again this much later.
    static let retryAfter: TimeInterval = 3600

    let db: AppDatabase
    let settings: SettingsStore
    let paths: AppPaths
    let serverVersion: String
    let rclone: () -> Rclone?

    private let lock = NSLock()
    private var activity: BackupActivity?

    public init(db: AppDatabase, settings: SettingsStore, paths: AppPaths, serverVersion: String,
                rclone: @escaping () -> Rclone? = { Rclone.locate() }) {
        self.db = db
        self.settings = settings
        self.paths = paths
        self.serverVersion = serverVersion
        self.rclone = rclone
    }

    public var current: BackupActivity? { lock.lock(); defer { lock.unlock() }; return activity }

    private func begin(_ kind: String) throws {
        lock.lock(); defer { lock.unlock() }
        if activity != nil { throw BackupError.busy }
        activity = BackupActivity(kind: kind, phase: "Starting", startedAt: Date())
    }

    private func phase(_ p: String, files: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        activity?.phase = p
        if let files { activity?.files = files }
    }

    private func end() { lock.lock(); activity = nil; lock.unlock() }

    public func destination() throws -> String { try settings.get(.backupDestination) ?? Self.defaultDestination }
    public func intervalHours() throws -> Int { try settings.get(.backupIntervalHours) ?? Self.defaultIntervalHours }

    // MARK: What there is to back up

    public struct LocalStats: Codable, Sendable, Equatable {
        public var databaseBytes: Int64
        public var assets: Int
        public var albums: Int
        public var uploadsFiles: Int
        public var uploadsBytes: Int64
    }

    public func localStats() throws -> LocalStats {
        let (assets, albums) = try counts()
        let dbBytes = ["", "-wal"].reduce(Int64(0)) { sum, s in
            sum + (((try? FileManager.default.attributesOfItem(atPath: paths.databaseURL.path + s))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let up = try settings.get(.uploadsPath).map { Self.folderStats(URL(fileURLWithPath: $0)) } ?? (0, 0)
        return LocalStats(databaseBytes: dbBytes, assets: assets, albums: albums, uploadsFiles: up.files, uploadsBytes: up.bytes)
    }

    func counts() throws -> (assets: Int, albums: Int) {
        try db.writer.read { d in
            (try Int.fetchOne(d, sql: """
                SELECT count(*) FROM asset a WHERE a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash t WHERE t.assetId = a.id)
                """) ?? 0,
             try Int.fetchOne(d, sql: "SELECT count(*) FROM album") ?? 0)
        }
    }

    /// Files and bytes in a folder, hidden ones (.incoming, .trash) left out — as backed up.
    static func folderStats(_ url: URL) -> (files: Int, bytes: Int64) {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return (0, 0) }
        var files = 0, bytes: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(v.fileSize ?? 0)
        }
        return (files, bytes)
    }

    /// Where photos come from, with a few sample files each (for the restore check).
    func sources() throws -> [BackupSource] {
        var list: [(root: String, kind: String, path: String)] = []
        if let lib = try settings.get(.libraryPath) { list.append((Roots.library, "local", lib)) }
        list += try LocalFolders.all(settings).map { ($0.root, "local", $0.path) }
        list += try PhotosLibraries.all(settings).map { ($0.root, "local", $0.path) }
        list += try RemoteSources.all(settings).map { ($0.root, "rclone", $0.path) }
        return try db.writer.read { d in
            try list.map { s in
                let files = try Int.fetchOne(d, sql: "SELECT count(*) FROM file WHERE root = ?", arguments: [s.root]) ?? 0
                let samples = try Row.fetchAll(d, sql: "SELECT relPath, size FROM file WHERE root = ? ORDER BY random() LIMIT 20",
                                               arguments: [s.root]).map { BackupSource.Sample(path: $0["relPath"], size: $0["size"]) }
                return BackupSource(root: s.root, kind: s.kind, path: s.path, files: files, samples: samples)
            }
        }
    }

    static func migrations(_ d: Database) throws -> [String] {
        try String.fetchAll(d, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }

    // MARK: Backing up

    /// Whether a scheduled backup is due (enabled, rclone there, nothing running, interval passed).
    public func isDue(now: Date = Date()) throws -> Bool {
        guard try settings.get(.backupEnabled), current == nil, rclone() != nil else { return false }
        guard let last = try settings.get(.lastBackup) else { return true }
        let wait = last.ok ? TimeInterval(try intervalHours()) * 3600 : Self.retryAfter
        return now.timeIntervalSince(last.startedAt) >= wait
    }

    /// Checks every few minutes whether a backup is due, and runs it.
    public func startScheduler(every: TimeInterval = 600) {
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 60)  // let the server settle first
            while true {
                do {
                    guard let s = self else { return }
                    if (try? s.isDue()) == true { _ = try? s.backup() }
                }
                Thread.sleep(forTimeInterval: every)
            }
        }
    }

    /// Backs up now (blocking; throws `busy` when one is running). The report is also saved.
    @discardableResult
    public func backup() throws -> BackupReport {
        try begin("backup")
        defer { end() }
        let started = Date()
        let dest = try destination()
        var report = BackupReport(startedAt: started, finishedAt: started, ok: false, destination: dest, databaseBytes: 0, assets: 0,
                                  albums: 0, uploadsFiles: 0, uploadsBytes: 0, uploadsCopied: 0)
        do {
            guard let rclone = rclone() else { throw RcloneError.notInstalled }
            let work = paths.dataDir.appendingPathComponent("backup-work", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            // a consistent copy while the server keeps running
            phase("Copying the database")
            let snapshot = work.appendingPathComponent("library.sqlite")
            try db.writer.writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [snapshot.path]) }
            let dbBytes = ((try FileManager.default.attributesOfItem(atPath: snapshot.path)[.size]) as? NSNumber)?.int64Value ?? 0
            let (assets, albums) = try counts()
            let migrations = try db.writer.read { try Self.migrations($0) }
            let sources = try sources()
            report.databaseBytes = dbBytes
            report.assets = assets
            report.albums = albums

            phase("Uploading the database")
            try rclone.copyFile(snapshot.path, to: Rclone.join(dest, "library.sqlite"))

            let uploadsPath = try settings.get(.uploadsPath)
            if let uploadsPath {
                let stats = Self.folderStats(URL(fileURLWithPath: uploadsPath))
                report.uploadsFiles = stats.files
                report.uploadsBytes = stats.bytes
                // the backup's uploads become the same as these: deleted ones go too (a destination
                // that keeps versions keeps them for a while)
                phase("Uploading new uploads", files: 0)
                let n = LockedBox(0)
                let synced = try rclone.syncFolder(uploadsPath, to: Rclone.join(dest, "uploads")) { [weak self] _ in
                    n.mutate { $0 += 1 }
                    self?.phase("Uploading new uploads", files: n.value)
                }
                report.uploadsCopied = synced.copied
                report.uploadsDeleted = synced.deleted
            }

            phase("Finishing")
            let manifest = BackupManifest(createdAt: started, serverVersion: serverVersion, migrations: migrations, databaseBytes: dbBytes,
                                          assets: assets, albums: albums, sources: sources, uploadsPath: uploadsPath,
                                          uploadsFiles: report.uploadsFiles, uploadsBytes: report.uploadsBytes)
            let mf = work.appendingPathComponent("manifest.json")
            try Self.encoder.encode(manifest).write(to: mf)
            try rclone.copyFile(mf.path, to: Rclone.join(dest, "manifest.json"))
            report.ok = true
        } catch {
            report.error = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        }
        report.finishedAt = Date()
        try settings.set(.lastBackup, report)
        if let e = report.error { throw RcloneError.failed(e) }
        return report
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Restoring

    /// Looks at a backup: what it holds, and whether it can be restored here — the database is one
    /// this server can open, and the folders its photos come from are still where they were.
    public func inspect(_ location: String) throws -> BackupInspection {
        guard let rclone = rclone() else { throw RcloneError.notInstalled }
        var checks: [BackupInspection.Check] = []
        var manifest: BackupManifest?
        do {
            manifest = try Self.decoder.decode(BackupManifest.self, from: try rclone.read(Rclone.join(location, "manifest.json")))
            checks.append(.init(title: "Backup", ok: true, detail: "Made \(Self.stamp(manifest!.createdAt)) by server \(manifest!.serverVersion)."))
        } catch RcloneError.notFound {
            checks.append(.init(title: "Backup", ok: false, detail: "No backup here (manifest.json is missing)."))
        } catch is DecodingError {
            checks.append(.init(title: "Backup", ok: false, detail: "manifest.json can't be read."))
        }
        let dbEntry = try rclone.stat(Rclone.join(location, "library.sqlite"))
        checks.append(dbEntry.map { .init(title: "Database", ok: true, detail: Self.bytes($0.Size)) }
                      ?? .init(title: "Database", ok: false, detail: "library.sqlite is missing."))
        let uploads = try rclone.size(Rclone.join(location, "uploads"))
        let uploadsTarget = try settings.get(.uploadsPath) ?? manifest?.uploadsPath

        if let manifest {
            let known = Set(try db.writer.read { try Self.migrations($0) })
            let unknown = manifest.migrations.filter { !known.contains($0) }
            let format = BackupFormat.check(manifest.version)
            let schema = manifest.migrations.max() ?? "none"
            checks.append(!format.ok
                          ? .init(title: "Version", ok: false, detail: format.detail)
                          : !unknown.isEmpty
                          ? .init(title: "Version", ok: false, detail: BackupError.newerDatabase.description)
                          : .init(title: "Version", ok: true, detail: "\(format.detail), database \(schema): this server can open it."))
            for s in manifest.sources { checks.append(check(s, rclone: rclone)) }
            if manifest.uploadsFiles > 0 || uploads.count > 0 {
                checks.append(uploadsTarget.map { .init(title: "Uploads", ok: true, detail: "\(uploads.count) files (\(Self.bytes(uploads.bytes))) go into \($0).") }
                              ?? .init(title: "Uploads", ok: false, detail: BackupError.noUploadsFolder.description))
            }
        }
        return BackupInspection(location: location, manifest: manifest, databaseBytes: dbEntry?.Size ?? 0, uploadsFiles: uploads.count,
                                uploadsBytes: uploads.bytes, uploadsTarget: uploadsTarget, checks: checks,
                                canRestore: !checks.isEmpty && checks.allSatisfy(\.ok))
    }

    /// Whether a source is still where it was: there, with its sample files at the same paths and sizes.
    func check(_ s: BackupSource, rclone: Rclone) -> BackupInspection.Check {
        let title = s.root == Roots.library || LocalFolders.isLocalFolder(s.root) ? "Library folder"
            : PhotosLibraries.isPhotos(s.root) ? "Photos library" : "Source \(s.path)"
        let found: [String: Int64]
        if s.kind == "local" {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: s.path, isDirectory: &isDir), isDir.boolValue else {
                return .init(title: title, ok: false, detail: "\(s.path) isn't there (moved, renamed, or its drive isn't connected).")
            }
            let base = URL(fileURLWithPath: s.path)
            found = Dictionary(s.samples.compactMap { sample in
                ((try? FileManager.default.attributesOfItem(atPath: base.appendingPathComponent(sample.path).path))?[.size] as? NSNumber)
                    .map { (sample.path, $0.int64Value) }
            }, uniquingKeysWith: { a, _ in a })
        } else {
            do { found = try rclone.sizes(in: s.path, files: s.samples.map(\.path)) } catch {
                return .init(title: title, ok: false, detail: "\(s.path): \((error as? CustomStringConvertible)?.description ?? "not reachable")")
            }
        }
        let matching = s.samples.filter { found[$0.path] == $0.size }.count
        // a few files may have been edited or removed since; most must be where they were
        let ok = s.samples.isEmpty || matching * 10 >= s.samples.count * 8
        return .init(title: title, ok: ok, detail: ok
                     ? "\(s.path): still there (\(matching) of \(s.samples.count) sample files match)."
                     : "\(s.path): only \(matching) of \(s.samples.count) sample files are where they were. Has the folder moved?")
    }

    /// Restores a backup: checks it, downloads the database and the uploads, and stages the database
    /// to replace the current one when the server restarts (the caller restarts it). The current
    /// database is kept as library.sqlite.pre-restore-<date>.bak.
    public func restore(_ location: String) throws -> BackupInspection {
        try begin("restore")
        defer { end() }
        phase("Checking the backup")
        let inspection = try inspect(location)
        guard inspection.canRestore else { throw BackupError.cannotRestore(inspection.checks.filter { !$0.ok }.map(\.detail)) }
        guard let rclone = rclone() else { throw RcloneError.notInstalled }

        let staged = Self.stagedURL(paths)
        let download = staged.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: download)
        phase("Downloading the database")
        try rclone.copyFile(Rclone.join(location, "library.sqlite"), to: download.path)
        // the database must open and be one this server knows
        do {
            let q = try DatabaseQueue(path: download.path, configuration: { var c = Configuration(); c.readonly = true; return c }())
            let applied = try q.read { try Self.migrations($0) }
            let known = Set(try db.writer.read { try Self.migrations($0) })
            if applied.contains(where: { !known.contains($0) }) { throw BackupError.newerDatabase }
            try q.close()
        } catch let e as BackupError {
            try? FileManager.default.removeItem(at: download)
            throw e
        } catch {
            try? FileManager.default.removeItem(at: download)
            throw BackupError.notADatabase
        }

        if inspection.uploadsFiles > 0, let target = inspection.uploadsTarget {
            phase("Downloading uploads", files: 0)
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
            let n = LockedBox(0)
            try rclone.copyFolder(Rclone.join(location, "uploads"), to: target, transfers: 16) { [weak self] _ in
                n.mutate { $0 += 1 }
                self?.phase("Downloading uploads", files: n.value)
            }
        }
        phase("Restarting")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: download, to: staged)
        let pending = PendingRestore(location: location, uploadsPath: inspection.uploadsTarget)
        try Self.encoder.encode(pending).write(to: Self.pendingURL(paths))
        return inspection
    }

    struct PendingRestore: Codable {
        var location: String
        var uploadsPath: String?
    }

    static func stagedURL(_ p: AppPaths) -> URL { p.dataDir.appendingPathComponent("library.sqlite.restore") }
    static func pendingURL(_ p: AppPaths) -> URL { p.dataDir.appendingPathComponent("restore.json") }

    /// At startup, before the database is opened: puts a staged restore in place, keeping the
    /// current database next to it. Returns whether it did.
    @discardableResult
    public static func applyStagedRestore(_ p: AppPaths) throws -> Bool {
        let fm = FileManager.default
        let staged = stagedURL(p)
        guard fm.fileExists(atPath: staged.path) else { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let keep = p.databaseURL.path + ".pre-restore-\(f.string(from: Date())).bak"
        for s in ["", "-wal", "-shm"] where fm.fileExists(atPath: p.databaseURL.path + s) {
            try fm.moveItem(atPath: p.databaseURL.path + s, toPath: keep + s)
        }
        try fm.moveItem(at: staged, to: p.databaseURL)
        return true
    }

    /// After the restored database is open: points it at this Mac's uploads folder, drops cached
    /// renders of edits (edit versions may be numbered again), and asks for a scan. Nil when there
    /// was no restore.
    @discardableResult
    public static func finishRestore(_ p: AppPaths, settings: SettingsStore) throws -> String? {
        let url = pendingURL(p)
        guard let data = try? Data(contentsOf: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let pending = try decoder.decode(PendingRestore.self, from: data)
        if let up = pending.uploadsPath { try settings.set(.uploadsPath, up) }
        let fm = FileManager.default
        if let e = fm.enumerator(at: p.cacheDir, includingPropertiesForKeys: nil) {
            for case let f as URL in e where f.lastPathComponent.range(of: #"_e[1-9][0-9]*\."#, options: .regularExpression) != nil {
                try? fm.removeItem(at: f)
            }
        }
        try? fm.removeItem(at: p.cacheDir.appendingPathComponent("exports", isDirectory: true))
        return pending.location
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
