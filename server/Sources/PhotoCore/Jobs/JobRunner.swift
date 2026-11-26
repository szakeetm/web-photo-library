import Foundation
import GRDB

public enum JobKind: String, Sendable, CaseIterable {
    case detectChanges = "detect-changes"
    case reindex
    case rebuildCaches = "rebuild-caches"
    case purgeMissing = "purge-missing"
    case importTakeoutAlbums = "import-takeout-albums"
    /// Find faces in photos not scanned yet, then group them into people.
    case faces
    /// Re-group faces into people from scratch (unnamed groups only).
    case recluster
    /// Recognise objects (Vision's classifier) in photos and videos not done yet.
    case objects
}

/// Runs library jobs one at a time on a background queue; state is persisted in the `job` table.
public final class JobRunner: @unchecked Sendable {
    let db: AppDatabase
    let settings: SettingsStore
    let derivatives: () -> DerivativeStore
    let serverTZ: TimeZone
    let excluding: [URL]
    /// Where the face model lives (<data location>/models); nil disables faces (tests).
    let dataDir: URL?
    /// The ffmpeg found at start-up, for video posters; nil when it isn't installed.
    let ffmpeg: URL?
    private var analyzer: FaceAnalyzer?
    private let queue = DispatchQueue(label: "photo.jobs", qos: .utility)
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var cancelled = Set<Int64>()
    private let gate = DispatchSemaphore(value: 1)
    /// Called with the ids of purged assets (Purge missing), e.g. to delete their video previews.
    public var onPurge: (([String]) -> Void)?
    /// Called by Rebuild caches after thumbnails and previews are cleared, e.g. to delete video previews.
    public var onClearCaches: (() throws -> Void)?

    public init(db: AppDatabase, settings: SettingsStore, derivatives: @escaping () -> DerivativeStore,
                serverTZ: TimeZone = .current, excluding: [URL] = [], dataDir: URL? = nil, ffmpeg: URL? = FFmpeg.locate()) {
        self.db = db
        self.ffmpeg = ffmpeg
        self.dataDir = dataDir
        self.excluding = excluding
        self.settings = settings
        self.derivatives = derivatives
        self.serverTZ = serverTZ
        // Jobs interrupted by a restart are marked failed; resumeInterrupted() starts them again.
        try? db.writer.write { d in
            let kinds = try String.fetchAll(d, sql: "SELECT DISTINCT kind FROM job WHERE state IN ('queued','running')")
            let resumed = kinds.compactMap(JobKind.init(rawValue:)).filter(Self.resumable.contains)
                .map { $0 == .rebuildCaches ? JobKind.detectChanges : $0 }
            self.interrupted = resumed.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            try d.execute(sql: "UPDATE job SET state = 'failed', error = 'Interrupted by server restart', endedAt = ? WHERE state IN ('queued','running')",
                          arguments: [Date()])
        }
    }

    /// Jobs that pick up where they stopped when run again: files already indexed, images already
    /// rendered and photos already scanned for faces are skipped. An interrupted Rebuild caches
    /// continues as Detect changes, which renders whatever is missing (rerunning it would start over).
    static let resumable: [JobKind] = [.detectChanges, .reindex, .rebuildCaches, .faces, .objects]
    private var interrupted: [JobKind] = []

    /// Restarts the jobs a server restart interrupted (call once the server is set up).
    public func resumeInterrupted() {
        let kinds = interrupted
        interrupted = []
        for k in kinds { enqueue(k) }
    }

    @discardableResult
    public func enqueue(_ kind: JobKind) -> Int64 {
        var row = JobRow(id: nil, kind: kind.rawValue, state: "queued", phase: nil, progress: 0, total: 0,
                         message: nil, error: nil, startedAt: nil, endedAt: nil)
        try? db.writer.write { try row.insert($0) }
        let id = row.id ?? 0
        group.enter()
        queue.async { [self] in
            gate.wait(); gate.signal()
            run(id: id, kind: kind)
            group.leave()
        }
        return id
    }

    public func cancel(id: Int64) {
        lock.lock(); cancelled.insert(id); lock.unlock()
    }

    /// Stops the jobs of `kind` that are running or waiting (when its analysis is turned off). The
    /// waiting ones show as cancelled right away; the running one stops at its next photo.
    public func cancelAll(_ kind: JobKind) {
        let rows = (try? db.writer.read {
            try JobRow.filter(Column("kind") == kind.rawValue && ["queued", "running"].contains(Column("state"))).fetchAll($0)
        }) ?? []
        for r in rows {
            guard let id = r.id else { continue }
            cancel(id: id)
            if r.state == "queued" { update(id) { $0.state = "cancelled"; $0.endedAt = Date() } }
        }
    }

    public func job(id: Int64) -> JobRow? { try? db.writer.read { try JobRow.fetchOne($0, key: id) } }

    public func current() -> JobRow? {
        try? db.writer.read { try JobRow.filter(Column("state") == "running").fetchOne($0) }
    }

    public func recent(limit: Int = 10) -> [JobRow] {
        (try? db.writer.read { try JobRow.order(Column("id").desc).limit(limit).fetchAll($0) }) ?? []
    }

    public func waitUntilIdle() { group.wait() }
    func pauseForTesting() { gate.wait() }
    func resumeForTesting() { gate.signal() }

    private func isCancelled(_ id: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(id)
    }

    // MARK: - Execution

    private func update(_ id: Int64, _ change: (inout JobRow) -> Void) {
        try? db.writer.write { d in
            guard var row = try JobRow.fetchOne(d, key: id) else { return }
            change(&row)
            try row.update(d)
        }
    }

    private func run(id: Int64, kind: JobKind) {
        if isCancelled(id) {
            update(id) { $0.state = "cancelled"; $0.endedAt = Date() }
            return
        }
        update(id) { $0.state = "running"; $0.startedAt = Date() }
        do {
            let message = try execute(id: id, kind: kind)
            update(id) { $0.state = "done"; $0.endedAt = Date(); $0.message = message; $0.progress = $0.total }
        } catch ScanError.cancelled {
            update(id) { $0.state = "cancelled"; $0.endedAt = Date() }
        } catch {
            let text = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            update(id) { $0.state = "failed"; $0.endedAt = Date(); $0.error = text }
        }
    }

    /// Thread-safe, throttled, never moves backwards.
    private func progressReporter(_ id: Int64, phase: String) -> @Sendable (Int, Int) -> Void {
        let state = MonotonicProgress()
        let started = Date()
        update(id) { $0.phase = phase; $0.progress = 0; $0.total = 0 }
        return { [self] done, total in
            guard state.advance(to: done) else { return }
            let finished = done == total
            if finished {
                FileHandle.standardError.write(Data(String(format: "job %lld phase %@: %d items in %.2fs\n", id, phase, total, Date().timeIntervalSince(started)).utf8))
            } else if !state.shouldPublish() {
                return
            }
            update(id) { row in
                if done >= row.progress { row.progress = done; row.total = total }
            }
        }
    }

    /// Configured roots, library first; remote sources' roots are their mirrors on this Mac. Every
    /// source is optional (the uploads folder is one too), as long as there is at least one.
    private func roots() throws -> [(String, URL)] {
        var out: [(String, URL)] = []
        if let lib = try settings.get(.libraryPath), !lib.isEmpty { out.append((Roots.library, URL(fileURLWithPath: lib))) }
        out += try LocalFolders.all(settings).map { ($0.root, $0.url) }
        if let up = try settings.get(.uploadsPath), !up.isEmpty { out.append((Roots.uploads, URL(fileURLWithPath: up))) }
        out += try PhotosLibraries.all(settings).map { ($0.root, $0.url) }
        out += try remoteRoots().map { ($0.root, $1) }
        if out.isEmpty { throw JobError.noLibrary }
        return out
    }

    private func remoteRoots() throws -> [(RemoteSource, URL)] {
        guard let dataDir else { return [] }
        return try RemoteSources.all(settings).map { ($0, RemoteSources.mirror($0.root, dataDir: dataDir)) }
    }

    private func execute(id: Int64, kind: JobKind) throws -> String {
        let cancelled = { [self] in isCancelled(id) }
        switch kind {
        case .detectChanges, .reindex:
            // The library must be readable; the uploads folder is optional and its problems are only reported.
            var total = ScanReport()
            var notes: [String] = []
            for (name, url) in try roots() {
                if PhotosLibraries.isPhotos(name) {
                    // an Apple Photos library: its own photos' originals, their names and its albums
                    guard let source = try PhotosLibraries.source(root: name, settings) else { continue }
                    do {
                        let (r, n) = try PhotosLibraries.scan(source, db: db, settings: settings, serverTZ: serverTZ,
                                                              progress: progressReporter(id, phase: "photos:\(name)"), isCancelled: cancelled)
                        total.merge(r)
                        notes += n
                        try? settings.recordScan(SourceScan(root: name, report: r, note: n.last))
                    } catch ScanError.rootUnreadable(let path) {
                        let note = "The Photos library isn't readable (\(path)): is its drive connected? Its photos were left untouched."
                        notes.append(note)
                        try? settings.recordScan(SourceScan(root: name, report: nil, note: note))
                    } catch let e as PhotosLibraryError {
                        notes.append(e.description)
                        try? settings.recordScan(SourceScan(root: name, report: nil, note: e.description))
                    }
                    continue
                }
                if RemoteSources.isRemote(name) {
                    // remote sources are listed with rclone; Re-index reads what changed there too
                    guard let dataDir, let source = try RemoteSources.source(root: name, settings) else { continue }
                    guard let rclone = Rclone.locate() else {
                        notes.append("rclone isn't installed: \(source.path) was not scanned.")
                        try? settings.recordScan(SourceScan(root: name, report: nil, note: "rclone isn't installed."))
                        continue
                    }
                    let store = derivatives()
                    let scanner = RemoteScanner(db: db, source: source, dataDir: dataDir, rclone: rclone, serverTZ: serverTZ,
                                                cacheBudget: try RemoteSources.cacheBytes(settings))
                    do {
                        let r = try scanner.detectChanges(progress: progressReporter(id, phase: "remote:\(name)"), isCancelled: cancelled) { made in
                            parallelFor(made.count, workers: self.workerCount) { i in
                                try? self.render(assetId: made[i].id, source: made[i].url, store: store)
                            }
                        }
                        total.merge(r)
                        try? settings.recordScan(SourceScan(root: name, report: r, note: r.errors.first))
                    } catch ScanError.rootUnreadable(let why) {
                        notes.append("Could not list \(why); its photos were left untouched.")
                        try? settings.recordScan(SourceScan(root: name, report: nil, note: "Could not list \(why)"))
                    }
                    continue
                }
                let scanner = LibraryScanner(db: db, root: url, rootName: name, serverTZ: serverTZ, excluding: excluding)
                // folders that are sources report their progress and result as their own
                let isSource = name == Roots.library || name == Roots.uploads || LocalFolders.isLocalFolder(name)
                do {
                    let r = kind == .reindex
                        ? try scanner.reindex(progress: progressReporter(id, phase: isSource ? "metadata:\(name)" : "metadata"), isCancelled: cancelled)
                        : try scanner.detectChanges(progress: progressReporter(id, phase: isSource ? "scan:\(name)" : "scan"), isCancelled: cancelled)
                    total.merge(r)
                    if isSource { try? settings.recordScan(SourceScan(root: name, report: r, note: r.errors.first)) }
                    if let f = try LocalFolders.source(root: name, settings) { try scanner.nameRootFolder(f.title) }
                    if name == Roots.library { try scanner.nameRootFolder(url.lastPathComponent) }
                } catch ScanError.rootUnreadable(let path) where name == Roots.uploads {
                    let note = "Uploads folder is not readable (\(path)); its photos were left untouched."
                    notes.append(note)
                    try? settings.recordScan(SourceScan(root: name, report: nil, note: note))
                } catch ScanError.rootUnreadable(let path) where LocalFolders.isLocalFolder(name) {
                    let note = "\(path) isn't readable (moved, or its drive isn't connected); its photos were left untouched."
                    notes.append(note)
                    try? settings.recordScan(SourceScan(root: name, report: nil, note: note))
                }
            }
            let failures = kind == .detectChanges ? try generateDerivatives(id: id, isCancelled: cancelled) : []
            let placed = try PlaceService(db: db).geocodePending()
            if placed > 0 { notes.append("\(placed) photo\(placed == 1 ? "" : "s") placed on the map.") }
            if kind == .detectChanges { enqueueFacesIfNeeded(); enqueueObjectsIfNeeded() }
            if kind == .detectChanges, let pending = try? AlbumService(db: db, settings: settings).pendingTakeoutAlbums(), pending > 0 {
                notes.append("\(pending) Google Takeout album\(pending == 1 ? "" : "s") can be imported (Settings → Import Takeout albums).")
            }
            _ = try? db.writer.write { try ChangeLog.compact($0) }
            return ([summary(total, renderFailures: failures)] + notes).joined(separator: "\n")
        case .rebuildCaches:
            try derivatives().clear()
            try onClearCaches?()
            try db.writer.write { try $0.execute(sql: "UPDATE asset SET blurhash = NULL") }
            let failures = try generateDerivatives(id: id, isCancelled: cancelled)
            return failures.isEmpty ? "Caches rebuilt" : "Caches rebuilt\n" + renderFailureText(failures)
        case .purgeMissing:
            let ids = try db.writer.write { d -> [String] in
                let ids = try String.fetchAll(d, sql: "SELECT id FROM asset WHERE missingSince IS NOT NULL")
                try AssetPurge.purge(ids, d)
                return ids
            }
            let store = derivatives()
            for a in ids { store.remove(id: a) }
            onPurge?(ids)
            return "Purged \(ids.count) missing photos"
        case .faces:
            return try scanFaces(id: id, isCancelled: cancelled)
        case .objects:
            return try scanObjects(id: id, isCancelled: cancelled)
        case .recluster:
            let n = try FaceService(db: db).cluster()
            return "\(n) group\(n == 1 ? "" : "s") of faces found"
        case .importTakeoutAlbums:
            let r = try AlbumService(db: db, settings: settings).importTakeoutAlbums()
            return "\(r.created) albums created, \(r.updated) updated"
        }
    }

    /// Queues a face scan when faces are on, the model is installed and photos are waiting.
    public func enqueueFacesIfNeeded() {
        guard let dataDir, FaceAnalyzer.modelInstalled(dataDir: dataDir),
              (try? settings.get(.facesEnabled)) ?? true,
              let pending = try? FaceService(db: db).pendingAssets(limit: 1), !pending.isEmpty else { return }
        let queued = recent(limit: 10).contains { $0.kind == JobKind.faces.rawValue && ($0.state == "queued" || $0.state == "running") }
        if !queued { enqueue(.faces) }
    }

    static let underTests = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }

    /// Queues object recognition when photos are waiting for it.
    public func enqueueObjectsIfNeeded() {
        // Not inside the test runner: its many parallel job runners block enough threads that Vision's
        // own work never gets one (Vision then waits forever). Tests that need objects run the job.
        guard !Self.underTests, (try? settings.get(.objectsEnabled)) ?? true else { return }
        guard let pending = try? Self.pendingAnalysis(db, limit: 1), !pending.isEmpty else { return }
        let queued = recent(limit: 10).contains { $0.kind == JobKind.objects.rawValue && ($0.state == "queued" || $0.state == "running") }
        if !queued { enqueue(.objects) }
    }

    /// Photos and videos missing any analysis (objects, text, fingerprints), newest first.
    static func pendingAnalysis(_ db: AppDatabase, limit: Int? = nil) throws -> [String] {
        try db.writer.read {
            try String.fetchAll($0, sql: """
                SELECT id FROM asset WHERE missingSince IS NULL
                  AND (objectsVersion < ? OR textVersion < ? OR printVersion < ?)
                ORDER BY takenAt DESC \(limit.map { "LIMIT \($0)" } ?? "")
                """, arguments: [ObjectService.version, TextService.version, DuplicateService.version])
        }
    }

    /// How many photos and videos (not missing) still need analysis, out of how many.
    public static func analysisCounts(_ db: AppDatabase) throws -> (pending: Int, total: Int) {
        try db.writer.read { d in
            let row = try Row.fetchOne(d, sql: """
                SELECT COUNT(*) AS total,
                       COALESCE(SUM(objectsVersion < ? OR textVersion < ? OR printVersion < ?), 0) AS pending
                FROM asset WHERE missingSince IS NULL
                """, arguments: [ObjectService.version, TextService.version, DuplicateService.version])
            return (row?["pending"] ?? 0, row?["total"] ?? 0)
        }
    }

    /// One pass per photo: the preview is decoded once for objects (classifier), text (OCR) and
    /// fingerprints (duplicates). Videos get objects only (from their poster).
    private func scanObjects(id: Int64, isCancelled: @escaping () -> Bool) throws -> String {
        guard (try? settings.get(.objectsEnabled)) ?? true else { return "Object recognition is turned off." }
        let objects = ObjectService(db: db)
        let texts = TextService(db: db)
        let duplicates = DuplicateService(db: db)
        let catalog = CatalogService(db: db, settings: settings)
        let store = derivatives()
        let ids = try Self.pendingAnalysis(db)
        let report = progressReporter(id, phase: "analyse")
        let counter = Counter()
        let found = Counter()
        let withText = Counter()
        // One at a time: Vision schedules the work on the Neural Engine itself, and calling it from
        // several worker threads at once can deadlock inside Vision.
        for assetId in ids {
            if isCancelled() { break }
            InteractiveWork.yield()
            autoreleasepool {
                let done = (try? db.writer.read { d in
                    try Row.fetchOne(d, sql: "SELECT objectsVersion, textVersion, printVersion, kind FROM asset WHERE id = ?", arguments: [assetId])
                }) ?? nil
                guard let done else { return }
                let isVideo = (done["kind"] as String) == "video"
                let needObjects = (done["objectsVersion"] as Int) < ObjectService.version
                let needText = (done["textVersion"] as Int) < TextService.version
                let needPrint = (done["printVersion"] as Int) < DuplicateService.version
                do {
                    // the preview (photos) or poster (videos)
                    var preview = store.url(id: assetId, kind: .preview, format: .heic)
                    if !FileManager.default.fileExists(atPath: preview.path) {
                        guard let src = try catalog.originals.original(id: assetId) else { return }
                        if isVideo {
                            preview = try store.ensurePoster(id: assetId, source: src, format: .heic, ffmpeg: ffmpeg).preview
                        } else {
                            preview = try store.ensure(id: assetId, source: src, kind: .preview, format: .heic)
                        }
                    }
                    // the classifier and fingerprints work at a few hundred pixels; text needs more
                    let small = try DerivativeStore.downscaled(source: preview, maxPixel: 512)
                    if needObjects {
                        let labels = try ObjectService.classify(small)
                        for _ in labels { _ = found.increment() }
                        try objects.store(assetId: assetId, labels: labels)
                    }
                    if needPrint {
                        if isVideo { try duplicates.store(assetId: assetId, dhash: nil, print: []) } else {
                            try duplicates.store(assetId: assetId, dhash: DuplicateService.dhash(small),
                                                 print: try DuplicateService.featurePrint(small))
                        }
                    }
                    if needText {
                        let text = isVideo ? "" : try TextService.recognize(try DerivativeStore.downscaled(source: preview, maxPixel: 1600))
                        if !text.isEmpty { _ = withText.increment() }
                        try texts.store(assetId: assetId, text: text)
                    }
                } catch {
                    // unreadable: mark it done so it isn't retried forever
                    if needObjects { try? objects.store(assetId: assetId, labels: []) }
                    if needPrint { try? duplicates.store(assetId: assetId, dhash: nil, print: []) }
                    if needText { try? texts.store(assetId: assetId, text: "") }
                }
            }
            report(counter.increment(), ids.count)
        }
        if isCancelled() { throw ScanError.cancelled }
        // search covers labels and text, duplicates the fingerprints: let them rebuild
        try db.writer.write { try ChangeLog.record($0, entity: "objects", id: "*", op: "upsert") }
        return "\(ids.count) photos and videos looked at: \(found.current) objects recognised, text found in \(withText.current)"
    }

    private func scanFaces(id: Int64, isCancelled: @escaping () -> Bool) throws -> String {
        guard (try? settings.get(.facesEnabled)) ?? true else { return "Face recognition is turned off." }
        guard let dataDir else { throw FaceError.modelMissing("no data location") }
        if analyzer == nil { analyzer = try FaceAnalyzer(dataDir: dataDir) }
        let analyzer = analyzer!
        let faces = FaceService(db: db)
        let catalog = CatalogService(db: db, settings: settings)
        let store = derivatives()
        let ids = try faces.pendingAssets()
        let report = progressReporter(id, phase: "faces")
        var found = 0
        for (i, assetId) in ids.enumerated() {
            InteractiveWork.yield()
            if isCancelled() { throw ScanError.cancelled }
            autoreleasepool {
                do {
                    var preview = store.url(id: assetId, kind: .preview, format: .heic)
                    if !FileManager.default.fileExists(atPath: preview.path) {
                        guard let src = try catalog.originals.original(id: assetId) else { return }
                        preview = try store.ensure(id: assetId, source: src, kind: .preview, format: .heic)
                    }
                    let image = try DerivativeStore.downscaled(source: preview, maxPixel: DerivativeKind.preview.maxPixel)
                    let detected = try analyzer.analyze(image)
                    found += detected.count
                    try faces.store(assetId: assetId, faces: detected)
                } catch {
                    // unreadable photo: mark it scanned so it isn't retried forever
                    try? faces.store(assetId: assetId, faces: [])
                }
            }
            report(i + 1, ids.count)
        }
        let groups = try faces.cluster()
        return "\(ids.count) photos scanned, \(found) faces found, \(groups) unnamed group\(groups == 1 ? "" : "s")"
    }

    private func renderFailureText(_ names: [String]) -> String {
        "\(names.count) photos could not be rendered: " + names.prefix(20).joined(separator: ", ")
    }

    private func summary(_ r: ScanReport, renderFailures: [String] = []) -> String {
        var s = "\(r.added) added, \(r.updated) updated, \(r.removed) removed, \(r.unchanged) unchanged"
        if r.skipped > 0 { s += ", \(r.skipped) skipped" }
        if r.skippedOther > 0 { s += ", \(r.skippedOther) other file\(r.skippedOther == 1 ? "" : "s") skipped" }
        if r.liveMotion > 0 { s += ", \(r.liveMotion) Live Photo video\(r.liveMotion == 1 ? "" : "s") attached" }
        if !renderFailures.isEmpty { s += "\n" + renderFailureText(renderFailures) }
        if !r.errors.isEmpty { s += "\n" + r.errors.prefix(50).joined(separator: "\n") }
        return s
    }

    /// Preview + thumbnail (+ BlurHash) for one asset, e.g. right after an upload.
    public func render(assetId: String, source: URL, store: DerivativeStore? = nil, needsBlurHash: Bool = true) throws {
        let store = store ?? derivatives()
        let isVideo = try db.writer.read { try String.fetchOne($0, sql: "SELECT kind FROM asset WHERE id = ?", arguments: [assetId]) } == "video"
        var made = isVideo
            ? try store.ensurePoster(id: assetId, source: source, format: .heic, ffmpeg: ffmpeg)
            : try store.ensureAll(id: assetId, source: source, format: .heic)
        // An edited photo also gets its current edit's preview + thumbnail; the placeholder follows the edit.
        // Edits never apply to videos.
        let edit = try db.writer.read { d -> (Int, EditRecipe)? in
            guard !isVideo else { return nil }
            guard let v = try Int.fetchOne(d, sql: "SELECT editVersion FROM asset WHERE id = ?", arguments: [assetId]), v > 0,
                  let r = try EditService.recipe(d, id: assetId, version: v) else { return nil }
            return (v, r)
        }
        if let (version, recipe) = edit {
            try EditService(db: db, catalog: CatalogService(db: db, settings: settings), derivatives: { store })
                .ensureRendered(id: assetId, version: version, recipe: recipe, source: source, formats: [.heic])
            made.thumb = store.url(id: assetId, kind: .thumb, editVersion: version, format: .heic)
        }
        if needsBlurHash, let img = try? DerivativeStore.downscaled(source: made.thumb, maxPixel: 64) {
            let bh = BlurHash.encode(cgImage: img)
            try db.writer.write {
                try $0.execute(sql: "UPDATE asset SET blurhash = ? WHERE id = ?", arguments: [bh, assetId])
                try ChangeLog.record($0, entity: "asset", id: assetId, op: "upsert")
            }
        }
    }

    var workerCount: Int {
        let configured = (try? settings.get(.workers)).flatMap { $0 } ?? Workers.defaultCount
        return max(1, min(configured, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Preview + thumbnail (+ BlurHash) per photo, newest first, one decode of the original each.
    @discardableResult
    private func generateDerivatives(id: Int64, isCancelled: @escaping () -> Bool) throws -> [String] {
        let bases = Dictionary(uniqueKeysWithValues: try roots())
        let store = derivatives()
        let rows = try db.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT a.id, a.blurhash, MIN(f.root || char(0) || f.relPath) AS loc FROM asset a JOIN file f ON f.assetId = a.id
                WHERE a.missingSince IS NULL GROUP BY a.id ORDER BY a.takenAt DESC
                """)
        }
        let items: [(id: String, url: URL?, rel: String, hasBH: Bool, remote: Bool)] = rows.map { r in
            let parts = (r["loc"] as String).split(separator: "\u{0}", maxSplits: 1).map(String.init)
            return (r["id"], bases[parts[0]].map { $0.appendingPathComponent(parts[1]) }, parts[1], (r["blurhash"] as String?) != nil,
                    RemoteSources.isRemote(parts[0]))
        }
        let catalog = CatalogService(db: db, settings: settings)
        let report = progressReporter(id, phase: "images")
        let counter = Counter()
        let failures = FailedDirs()
        parallelFor(items.count, workers: workerCount) { i in
            if isCancelled() { return }
            InteractiveWork.yield()
            let item = items[i]
            do {
                if item.remote {
                    // a remote original is only fetched when its images are missing
                    if item.hasBH && store.exists(id: item.id, kind: .thumb, format: .heic)
                        && store.exists(id: item.id, kind: .preview, format: .heic) { return report(counter.increment(), items.count) }
                    guard let source = try catalog.originals.original(id: item.id) else { throw ScanError.rootUnreadable(item.rel) }
                    try render(assetId: item.id, source: source, store: store, needsBlurHash: !item.hasBH)
                    return report(counter.increment(), items.count)
                }
                guard let source = item.url else { throw ScanError.rootUnreadable(item.rel) }
                try render(assetId: item.id, source: source, store: store, needsBlurHash: !item.hasBH)
            } catch {
                failures.add(item.rel)
            }
            report(counter.increment(), items.count)
        }
        if isCancelled() { throw ScanError.cancelled }
        return failures.paths.sorted()
    }
}

public enum JobError: Error, CustomStringConvertible {
    case noLibrary
    public var description: String { "No photos to show yet: choose a library folder or an uploads folder, or add another source, in Settings." }
}

/// Progress that only moves forward; publishing is throttled to ~4 updates per second.
public final class MonotonicProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    private var lastPublish = Date.distantPast
    public init() {}
    public func advance(to n: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard n > value else { return false }
        value = n
        return true
    }
    public func shouldPublish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastPublish) > 0.25 else { return false }
        lastPublish = now
        return true
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
