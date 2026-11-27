import CoreServices
import Foundation

/// Which changes under a watched source count, and how. Pure, so it can be tested.
public enum WatchPaths {
    public enum Kind: Equatable, Sendable {
        /// Not one the scan reads (hidden files, the server's own data, Photos' caches): ignored.
        case ignored
        /// A file the scan reads changed: scan.
        case files
        /// Only the Photos database changed: scan if the quick check finds a difference.
        case database
    }

    /// `path` is under the source `root` (a folder, or a .photoslibrary when `photos`). Compared without
    /// case (volumes usually ignore it); `excluding` are lowercased paths.
    public static func classify(_ path: String, root: String, photos: Bool, excluding: [String] = []) -> Kind {
        let path = path.lowercased(), root = root.lowercased()
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) || path == root else { return .ignored }
        if excluding.contains(where: { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { return .ignored }
        let rel = path == root ? "" : String(path.dropFirst(base.count))
        if photos {
            // originals arriving from iCloud, and edits (rendered by Photos): files the scan reads
            if rel.hasPrefix("originals/") || rel.hasPrefix("resources/renders/") { return .files }
            // deletions, hiding, albums, dates and places only change the database
            if rel == "database/photos.sqlite" || rel == "database/photos.sqlite-wal" { return .database }
            return .ignored  // thumbnails, analysis, search index, caches
        }
        // the scan skips hidden files and folders (.DS_Store, .Trash, the uploads Trash, partial copies)
        if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return .ignored }
        return .files
    }
}

/// When to scan a source after its changes: once they have been quiet for `quiet`, or at the latest
/// `cap` after the first one (a long iCloud download shows up in waves instead of only at its end).
public struct WatchDebounce: Sendable, Equatable {
    public static let quiet: TimeInterval = 20
    public static let cap: TimeInterval = 120

    public private(set) var first: Date?
    public private(set) var last: Date?
    /// Every change so far was in the Photos database only (the quick check decides).
    public private(set) var databaseOnly = true

    public init() {}

    public var pending: Bool { first != nil }

    public mutating func record(_ kind: WatchPaths.Kind, at now: Date) {
        guard kind != .ignored else { return }
        if first == nil { first = now }
        last = now
        if kind == .files { databaseOnly = false }
    }

    public func due(at now: Date, quiet: TimeInterval = Self.quiet, cap: TimeInterval = Self.cap) -> Bool {
        guard let first, let last else { return false }
        return now.timeIntervalSince(last) >= quiet || now.timeIntervalSince(first) >= cap
    }

    public mutating func reset() { self = WatchDebounce() }
}

extension SettingKey where T == [String: SourceWatcher.Mark] {
    /// Where each watched source's change history was read up to, so changes made while the server
    /// was stopped are replayed when it starts.
    static let sourceWatchMarks = SettingKey("sourceWatchMarks", default: [:])
}

/// Watches the sources set to Immediate (local folders, the library and uploads folders, Photos
/// libraries) with FSEvents and queues a Detect changes of a source once its changes have settled.
/// Remote (rclone) sources can't be watched: what changes on the remote side never reaches this Mac.
public final class SourceWatcher: @unchecked Sendable {
    public struct Mark: Codable, Sendable, Equatable {
        /// the last event read
        public var eventId: UInt64
        /// the volume's change history it belongs to (a reformatted or replaced drive has another)
        public var history: String
    }

    private struct Watch {
        let root: String
        let path: String
        let photos: Bool
        let device: dev_t
        let stream: FSEventStreamRef
        var debounce = WatchDebounce()
        var lastEventId: UInt64 = 0
        /// the Photos database as last checked (nil: not checked since start)
        var fingerprint: String?
    }

    private unowned let jobs: JobRunner
    private let queue = DispatchQueue(label: "photo.watch", qos: .utility)
    private var watches: [String: Watch] = [:]
    private var timer: DispatchSourceTimer?
    /// The debounce timings (shorter in tests).
    var quiet = WatchDebounce.quiet, cap = WatchDebounce.cap, tickEvery: TimeInterval = 2
    private var excluding: [String] { jobs.excluding.map { PathOverlap.normalized($0.path) } }

    init(jobs: JobRunner) { self.jobs = jobs }

    /// Roots that can be watched: everything but remote sources.
    public static func canWatch(_ root: String) -> Bool { !RemoteSources.isRemote(root) }

    /// Starts and stops streams to match the settings (sources set to Immediate). Also restarts a
    /// stream whose folder came back (a drive connected again).
    public func sync() {
        queue.async { [self] in syncNow() }
    }

    private func syncNow() {
        let intervals = (try? jobs.settings.get(.sourceRefreshMinutes)) ?? [:]
        let wanted = ((try? jobs.roots()) ?? []).filter { root, _ in
            intervals[root] == SourceRefresh.immediate && Self.canWatch(root)
        }
        var keep = Set<String>()
        for (root, url) in wanted {
            // FSEvents reports real paths (/private/var/…, which resolvingSymlinksInPath turns back into /var/…)
            guard let real = realpath(url.path, nil) else { continue }  // not there now (drive not connected): try again later
            let path = String(cString: real)
            free(real)
            var st = stat()
            guard stat(path, &st) == 0 else { continue }
            keep.insert(root)
            if let w = watches[root], w.path == path, w.device == st.st_dev { continue }
            if let w = watches[root] { stop(w) }
            start(root: root, path: path, photos: PhotosLibraries.isPhotos(root), device: st.st_dev)
        }
        for (root, w) in watches where !keep.contains(root) {
            stop(w)
            watches[root] = nil
        }
        if watches.isEmpty {
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + tickEvery, repeating: tickEvery)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    private func start(root: String, path: String, photos: Bool, device: dev_t) {
        let history = FSEventsCopyUUIDForDevice(device).map { CFUUIDCreateString(nil, $0) as String } ?? ""
        let mark = ((try? jobs.settings.get(.sourceWatchMarks)) ?? [:])[root]
        // the change history since the last run, when it is still the same volume's history
        let since = mark.flatMap { $0.history == history && !history.isEmpty ? $0.eventId : nil }
        let box = Unmanaged.passRetained(CallbackBox(watcher: self, root: root))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil,
                                           release: { Unmanaged<CallbackBox>.fromOpaque($0!).release() }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                                             | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, ids in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var events: [(String, FSEventStreamEventFlags, UInt64)] = []
            for i in 0..<count where i < list.count { events.append((list[i], flags[i], ids[i])) }
            box.watcher?.received(box.root, events)
        }, &context, [path] as CFArray, since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            box.release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        var w = Watch(root: root, path: path, photos: photos, device: device, stream: stream)
        w.lastEventId = since ?? FSEventsGetCurrentEventId()
        watches[root] = w
        if since == nil {
            // no history to replay (first watch, or another volume): catch up once with a scan
            if mark != nil { watches[root]?.debounce.record(.files, at: .distantPast) }
            saveMark(root)
        }
    }

    private func stop(_ w: Watch) {
        FSEventStreamStop(w.stream)
        FSEventStreamInvalidate(w.stream)
        FSEventStreamRelease(w.stream)
    }

    /// FSEvents callback (on `queue`).
    private func received(_ root: String, _ events: [(String, FSEventStreamEventFlags, UInt64)]) {
        guard var w = watches[root] else { return }
        let now = Date()
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                             | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
                                             | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount
                                             | kFSEventStreamEventFlagUnmount)
        let excluding = excluding
        for (path, flags, id) in events {
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            w.lastEventId = max(w.lastEventId, id)
            if flags & rescan != 0 {
                // events were lost, or the folder moved / its drive came or went: look at all of it
                w.debounce.record(.files, at: now)
                continue
            }
            w.debounce.record(WatchPaths.classify(path, root: w.path, photos: w.photos, excluding: excluding), at: now)
        }
        watches[root] = w
        if events.contains(where: { $0.1 & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }) {
            syncNow()  // the folder is gone or moved: restart (or stop) its stream
        }
    }

    /// Every 2 s: queues the scans whose changes have settled.
    private func tick() {
        let now = Date()
        for (root, w) in watches where w.debounce.due(at: now, quiet: quiet, cap: cap) {
            switch jobs.scanState(root) {
            case .running:
                continue  // it may have read past some of the changes: scan again once it is done
            case .queued:
                break  // the waiting scan will see them
            case .none:
                if w.debounce.databaseOnly, w.photos {
                    let print = try? PhotosLibraryReader.fingerprint(URL(fileURLWithPath: w.path))
                    let unchanged = print != nil && print == w.fingerprint
                    watches[root]?.fingerprint = print
                    if !unchanged { jobs.enqueue(.detectChanges, target: root, watched: true) }
                } else {
                    if w.photos { watches[root]?.fingerprint = try? PhotosLibraryReader.fingerprint(URL(fileURLWithPath: w.path)) }
                    jobs.enqueue(.detectChanges, target: root, watched: true)
                }
            }
            watches[root]?.debounce.reset()
            saveMark(root)
        }
    }

    private func saveMark(_ root: String) {
        guard let w = watches[root] else { return }
        let history = FSEventsCopyUUIDForDevice(w.device).map { CFUUIDCreateString(nil, $0) as String } ?? ""
        var marks = (try? jobs.settings.get(.sourceWatchMarks)) ?? [:]
        marks = marks.filter { watches[$0.key] != nil }
        marks[root] = Mark(eventId: w.lastEventId, history: history)
        try? jobs.settings.set(.sourceWatchMarks, marks)
    }

    /// What a stream's callback holds: the watcher (weakly) and its source.
    private final class CallbackBox {
        weak var watcher: SourceWatcher?
        let root: String
        init(watcher: SourceWatcher, root: String) { self.watcher = watcher; self.root = root }
    }
}
