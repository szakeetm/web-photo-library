import Foundation

extension SettingKey where T == [String: Int] {
    /// Auto-refresh of each source: root → minutes between Detect changes runs. A source not listed
    /// (the default) is only scanned when asked.
    public static let sourceRefreshMinutes = SettingKey("sourceRefreshMinutes", default: [:])
}

/// Sources looked at again on their own, every few minutes to every week (a Photos library synced
/// with iCloud changes often; a pCloud folder rarely).
public enum SourceRefresh {
    /// The intervals offered, in minutes: 5 min, 15 min, 1 hour, 6 hours, 1 day, 1 week.
    public static let choices = [5, 15, 60, 360, 1440, 10080]

    /// The sources due for a refresh, most overdue first: their interval has passed since their last
    /// scan (or they were never scanned).
    public static func due(intervals: [String: Int], scans: [SourceScan], now: Date = Date()) -> [String] {
        let last = Dictionary(scans.map { ($0.root, $0.at) }, uniquingKeysWith: max)
        return intervals
            .compactMap { root, minutes -> (String, TimeInterval)? in
                guard minutes > 0 else { return nil }
                let since = last[root].map { now.timeIntervalSince($0) } ?? .infinity
                let over = since - TimeInterval(minutes) * 60
                return over >= 0 ? (root, over) : nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

extension JobRunner {
    /// Every source's root (library, local folders, uploads, Photos libraries, rclone folders).
    public func sourceRoots() throws -> [String] { try roots().map(\.0) }

    /// Whether a scan of `root` (or of every source) is waiting or running.
    func scanPending(_ root: String) -> Bool {
        recent(limit: 20).contains { j in
            ["queued", "running"].contains(j.state)
                && (j.kind == JobKind.reindex.rawValue || j.kind == JobKind.rebuildCaches.rawValue
                    || (j.kind == JobKind.detectChanges.rawValue && (j.target == nil || j.target == root)))
        }
    }

    /// Queues the sources whose auto-refresh is due. Sources that are gone are forgotten.
    public func refreshDueSources(now: Date = Date()) {
        guard var intervals = try? settings.get(.sourceRefreshMinutes), !intervals.isEmpty else { return }
        let known = Set(((try? sourceRoots()) ?? []))
        let gone = intervals.keys.filter { !known.contains($0) }
        if !gone.isEmpty {
            for r in gone { intervals.removeValue(forKey: r) }
            try? settings.set(.sourceRefreshMinutes, intervals)
        }
        let scans = (try? settings.get(.sourceScans)) ?? []
        for root in SourceRefresh.due(intervals: intervals, scans: scans, now: now) where !scanPending(root) {
            enqueue(.detectChanges, target: root)
        }
    }

    /// Checks every minute for sources due for their auto-refresh.
    public func startRefreshScheduler(every: TimeInterval = 60) {
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 30)  // let the server settle first
            while let self {
                self.refreshDueSources()
                Thread.sleep(forTimeInterval: every)
            }
        }
    }
}
