import Foundation
import GRDB

public enum JobKind: String, Sendable, CaseIterable {
    case detectChanges = "detect-changes"
    case reindex
    case rebuildCaches = "rebuild-caches"
    case purgeMissing = "purge-missing"
    case importTakeoutAlbums = "import-takeout-albums"
}

/// Runs library jobs one at a time on a background queue; state is persisted in the `job` table.
public final class JobRunner: @unchecked Sendable {
    let db: AppDatabase
    let settings: SettingsStore
    let derivatives: () -> DerivativeStore
    let serverTZ: TimeZone
    let excluding: [URL]
    private let queue = DispatchQueue(label: "photo.jobs", qos: .utility)
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var cancelled = Set<Int64>()
    private let gate = DispatchSemaphore(value: 1)

    public init(db: AppDatabase, settings: SettingsStore, derivatives: @escaping () -> DerivativeStore,
                serverTZ: TimeZone = .current, excluding: [URL] = []) {
        self.db = db
        self.excluding = excluding
        self.settings = settings
        self.derivatives = derivatives
        self.serverTZ = serverTZ
        // Jobs interrupted by a restart are marked failed.
        try? db.writer.write {
            try $0.execute(sql: "UPDATE job SET state = 'failed', error = 'Interrupted by server restart', endedAt = ? WHERE state IN ('queued','running')",
                           arguments: [Date()])
        }
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

    /// Configured roots, library first.
    private func roots() throws -> [(String, URL)] {
        var out = [(Roots.library, try libraryRoot())]
        if let up = try settings.get(.uploadsPath), !up.isEmpty { out.append((Roots.uploads, URL(fileURLWithPath: up))) }
        return out
    }

    private func libraryRoot() throws -> URL {
        guard let path = try settings.get(.libraryPath), !path.isEmpty else {
            throw JobError.noLibrary
        }
        return URL(fileURLWithPath: path)
    }

    private func execute(id: Int64, kind: JobKind) throws -> String {
        let cancelled = { [self] in isCancelled(id) }
        switch kind {
        case .detectChanges, .reindex:
            // The library must be readable; the uploads folder is optional and its problems are only reported.
            var total = ScanReport()
            var notes: [String] = []
            for (name, url) in try roots() {
                let scanner = LibraryScanner(db: db, root: url, rootName: name, serverTZ: serverTZ, excluding: excluding)
                do {
                    let r = kind == .reindex
                        ? try scanner.reindex(progress: progressReporter(id, phase: "metadata"), isCancelled: cancelled)
                        : try scanner.detectChanges(progress: progressReporter(id, phase: "scan"), isCancelled: cancelled)
                    total.merge(r)
                } catch ScanError.rootUnreadable(let path) where name == Roots.uploads {
                    notes.append("Uploads folder is not readable (\(path)); its photos were left untouched.")
                }
            }
            let failures = kind == .detectChanges ? try generateDerivatives(id: id, isCancelled: cancelled) : []
            if kind == .detectChanges, let pending = try? AlbumService(db: db, settings: settings).pendingTakeoutAlbums(), pending > 0 {
                notes.append("\(pending) Google Takeout album\(pending == 1 ? "" : "s") can be imported (Settings → Import Takeout albums).")
            }
            return ([summary(total, renderFailures: failures)] + notes).joined(separator: "\n")
        case .rebuildCaches:
            try derivatives().clear()
            try db.writer.write { try $0.execute(sql: "UPDATE asset SET blurhash = NULL") }
            let failures = try generateDerivatives(id: id, isCancelled: cancelled)
            return failures.isEmpty ? "Caches rebuilt" : "Caches rebuilt\n" + renderFailureText(failures)
        case .purgeMissing:
            let ids = try db.writer.write { d -> [String] in
                let ids = try String.fetchAll(d, sql: "SELECT id FROM asset WHERE missingSince IS NOT NULL")
                for a in ids { try ChangeLog.record(d, entity: "asset", id: a, op: "delete") }
                try d.execute(sql: "DELETE FROM album_asset WHERE assetId IN (SELECT id FROM asset WHERE missingSince IS NOT NULL)")
                try d.execute(sql: "DELETE FROM edit WHERE assetId IN (SELECT id FROM asset WHERE missingSince IS NOT NULL)")
                try d.execute(sql: "DELETE FROM asset WHERE missingSince IS NOT NULL")
                return ids
            }
            let store = derivatives()
            for a in ids { store.remove(id: a) }
            return "Purged \(ids.count) missing photos"
        case .importTakeoutAlbums:
            let r = try AlbumService(db: db, settings: settings).importTakeoutAlbums()
            return "\(r.created) albums created, \(r.updated) updated"
        }
    }

    private func renderFailureText(_ names: [String]) -> String {
        "\(names.count) photos could not be rendered: " + names.prefix(20).joined(separator: ", ")
    }

    private func summary(_ r: ScanReport, renderFailures: [String] = []) -> String {
        var s = "\(r.added) added, \(r.updated) updated, \(r.removed) removed, \(r.unchanged) unchanged"
        if r.skipped > 0 { s += ", \(r.skipped) skipped" }
        if r.skippedOther > 0 { s += ", \(r.skippedOther) videos/other files skipped" }
        if !renderFailures.isEmpty { s += "\n" + renderFailureText(renderFailures) }
        if !r.errors.isEmpty { s += "\n" + r.errors.prefix(50).joined(separator: "\n") }
        return s
    }

    /// Preview + thumbnail (+ BlurHash) for one asset, e.g. right after an upload.
    public func render(assetId: String, source: URL, store: DerivativeStore? = nil, needsBlurHash: Bool = true) throws {
        let store = store ?? derivatives()
        var made = try store.ensureAll(id: assetId, source: source, format: .heic)
        // An edited photo also gets its current edit's preview + thumbnail; the placeholder follows the edit.
        let edit = try db.writer.read { d -> (Int, EditRecipe)? in
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
        let items: [(id: String, url: URL?, rel: String, hasBH: Bool)] = rows.map { r in
            let parts = (r["loc"] as String).split(separator: "\u{0}", maxSplits: 1).map(String.init)
            return (r["id"], bases[parts[0]].map { $0.appendingPathComponent(parts[1]) }, parts[1], (r["blurhash"] as String?) != nil)
        }
        let report = progressReporter(id, phase: "images")
        let counter = Counter()
        let failures = FailedDirs()
        parallelFor(items.count, workers: workerCount) { i in
            if isCancelled() { return }
            let item = items[i]
            do {
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
    public var description: String { "No library folder configured. Choose one in Settings." }
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
}
