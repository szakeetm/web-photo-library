import Foundation
import GRDB

public enum JobKind: String, Sendable, CaseIterable {
    case detectChanges = "detect-changes"
    case reindex
    case rebuildCaches = "rebuild-caches"
    case purgeMissing = "purge-missing"
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

    private func progressReporter(_ id: Int64, phase: String) -> (Int, Int) -> Void {
        var last = Date.distantPast
        update(id) { $0.phase = phase; $0.progress = 0; $0.total = 0 }
        return { [self] done, total in
            let now = Date()
            guard done == total || now.timeIntervalSince(last) > 0.25 else { return }
            last = now
            update(id) { $0.progress = done; $0.total = total }
        }
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
        case .detectChanges:
            let scanner = LibraryScanner(db: db, root: try libraryRoot(), serverTZ: serverTZ, excluding: excluding)
            let r = try scanner.detectChanges(progress: progressReporter(id, phase: "scan"), isCancelled: cancelled)
            try generateDerivatives(id: id, isCancelled: cancelled)
            return summary(r)
        case .reindex:
            let scanner = LibraryScanner(db: db, root: try libraryRoot(), serverTZ: serverTZ, excluding: excluding)
            let r = try scanner.reindex(progress: progressReporter(id, phase: "metadata"), isCancelled: cancelled)
            return summary(r)
        case .rebuildCaches:
            try derivatives().clear()
            try db.writer.write { try $0.execute(sql: "UPDATE asset SET blurhash = NULL") }
            try generateDerivatives(id: id, isCancelled: cancelled)
            return "Caches rebuilt"
        case .purgeMissing:
            let n = try db.writer.write { d -> Int in
                let ids = try String.fetchAll(d, sql: "SELECT id FROM asset WHERE missingSince IS NOT NULL")
                for a in ids { try ChangeLog.record(d, entity: "asset", id: a, op: "delete") }
                try d.execute(sql: "DELETE FROM asset WHERE missingSince IS NOT NULL")
                return ids.count
            }
            return "Purged \(n) missing photos"
        }
    }

    private func summary(_ r: ScanReport) -> String {
        var s = "\(r.added) added, \(r.updated) updated, \(r.removed) removed, \(r.unchanged) unchanged"
        if r.skipped > 0 { s += ", \(r.skipped) skipped" }
        if !r.errors.isEmpty { s += "\n" + r.errors.prefix(50).joined(separator: "\n") }
        return s
    }

    /// Thumbnails (+ BlurHash) for everything first, then previews.
    private func generateDerivatives(id: Int64, isCancelled: @escaping () -> Bool) throws {
        let root = try libraryRoot()
        let store = derivatives()
        let rows = try db.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT a.id, a.blurhash, MIN(f.relPath) AS relPath FROM asset a JOIN file f ON f.assetId = a.id
                WHERE a.missingSince IS NULL GROUP BY a.id ORDER BY a.takenAt DESC
                """)
        }
        let items: [(id: String, rel: String, hasBH: Bool)] = rows.map { ($0["id"], $0["relPath"], ($0["blurhash"] as String?) != nil) }

        for kind in DerivativeKind.allCases {
            let report = progressReporter(id, phase: kind == .thumb ? "thumbnails" : "previews")
            let counter = Counter()
            let failed = Counter()
            DispatchQueue.concurrentPerform(iterations: items.count) { i in
                if isCancelled() { return }
                let item = items[i]
                let source = root.appendingPathComponent(item.rel)
                do {
                    let url = try store.ensure(id: item.id, source: source, kind: kind, format: .heic)
                    if kind == .thumb && !item.hasBH, let img = try? DerivativeStore.downscaled(source: url, maxPixel: 64) {
                        let bh = BlurHash.encode(cgImage: img)
                        try? db.writer.write {
                            try $0.execute(sql: "UPDATE asset SET blurhash = ? WHERE id = ?", arguments: [bh, item.id])
                            try ChangeLog.record($0, entity: "asset", id: item.id, op: "upsert")
                        }
                    }
                } catch {
                    failed.increment()
                }
                report(counter.increment(), items.count)
            }
            if isCancelled() { throw ScanError.cancelled }
        }
    }
}

public enum JobError: Error, CustomStringConvertible {
    case noLibrary
    public var description: String { "No library folder configured. Choose one in Settings." }
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
