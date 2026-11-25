import Foundation
import GRDB

/// Where a video's browser-playable preview stands.
/// JSON: `{"state": "ready"|"converting"|"queued"|"failed"|"unavailable", "progress"?: Double, "error"?: String}`.
public enum VideoStatus: Equatable, Sendable, Codable {
    case ready                 // preview exists, or servePlan == original
    case converting(Double)    // 0...1
    case queued
    case failed(String)
    case unavailable           // ffmpeg missing

    private enum CodingKeys: String, CodingKey { case state, progress, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "ready": self = .ready
        case "converting": self = .converting(try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0)
        case "queued": self = .queued
        case "failed": self = .failed(try c.decodeIfPresent(String.self, forKey: .error) ?? "")
        case "unavailable": self = .unavailable
        case let s: throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "unknown state \(s)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready: try c.encode("ready", forKey: .state)
        case .converting(let p): try c.encode("converting", forKey: .state); try c.encode(p, forKey: .progress)
        case .queued: try c.encode("queued", forKey: .state)
        case .failed(let e): try c.encode("failed", forKey: .state); try c.encode(e, forKey: .error)
        case .unavailable: try c.encode("unavailable", forKey: .state)
        }
    }
}

/// The "Convert all" run, for Settings.
public struct ConvertAllState: Codable, Sendable, Equatable {
    public var state: String   // "idle" | "running" | "paused"
    public var done: Int; public var total: Int
    public var current: String?; public var progress: Double?
    public var needed: Int     // videos with servePlan == preview and no preview
    public var converted: Int; public var bytes: Int64
    public var ffmpeg: Bool
}

/// Converts videos (and unplayable Live Photo motion clips) into HEVC MP4 previews with ffmpeg,
/// one at a time on a dedicated thread. On-demand requests run before "Convert all" work.
/// All state is in memory except `asset.videoError` (failures of videos, not of motion clips).
public final class VideoConversions: @unchecked Sendable {
    let db: AppDatabase
    let catalog: CatalogService
    let cacheDir: URL
    let ffmpeg: URL?
    /// Called on the worker right before ffmpeg is launched (tests count launches).
    var onLaunch: (() -> Void)?
    /// ffmpeg is killed when it writes no progress for this long.
    var stallTimeout: TimeInterval = 60

    private struct Job: Equatable { let id: String; let motion: Bool }
    private enum Cancel { case discard, requeue }
    /// Mutated only with `cond` held.
    private final class Running: @unchecked Sendable {
        let job: Job
        let fromAll: Bool
        /// An on-demand job taken out of the "Convert all" list: it still counts toward `done`.
        let counted: Bool
        var forAll: Bool { fromAll || counted }
        var progress = 0.0
        var name: String?
        var process: Process?
        var cancelled: Cancel?
        init(job: Job, fromAll: Bool, counted: Bool = false) { self.job = job; self.fromAll = fromAll; self.counted = counted }
    }

    /// Guards everything below.
    private let cond = NSCondition()
    private var onDemand: [Job] = []
    private var allList: [String] = []
    private var running: Running?
    private var workerActive = false
    private var runState = "idle"
    private var done = 0
    private var total = 0
    private var motionFailures: [String: String] = [:]
    /// "Convert all" ids moved to `onDemand` by a request.
    private var promoted = Set<String>()

    public init(db: AppDatabase, catalog: CatalogService, cacheDir: URL, ffmpeg: URL?) {
        self.db = db
        self.catalog = catalog
        self.cacheDir = cacheDir
        self.ffmpeg = ffmpeg
        // Leftovers of a conversion interrupted by a crash or a restart.
        for url in files() where url.lastPathComponent.contains(".tmp.") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var videoDir: URL { cacheDir.appendingPathComponent("video", isDirectory: true) }

    private func dir(_ id: String) -> URL { videoDir.appendingPathComponent(String(id.prefix(2)), isDirectory: true) }

    public func previewURL(id: String) -> URL { dir(id).appendingPathComponent("\(id).mp4") }

    public func motionPreviewURL(id: String) -> URL { dir(id).appendingPathComponent("\(id).motion.mp4") }

    private func output(_ job: Job) -> URL { job.motion ? motionPreviewURL(id: job.id) : previewURL(id: job.id) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func files() -> [URL] {
        guard let e = FileManager.default.enumerator(at: videoDir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "mp4" || $0.pathExtension == "log" }
    }

    // MARK: - Status

    /// A video (or, with `motion`, a still's motion clip) that is neither converted nor failed reports `.queued`.
    public func status(id: String, motion: Bool = false) -> VideoStatus {
        let job = Job(id: id, motion: motion)
        cond.lock()
        let live = liveStatus(job)
        cond.unlock()
        return live ?? storedStatus(job)
    }

    /// Requests a conversion ahead of "Convert all" work; a conversion already queued or running is shared.
    /// A failed video is not retried here ("Convert all" or a re-index does that).
    @discardableResult
    public func request(id: String, motion: Bool = false) -> VideoStatus {
        let job = Job(id: id, motion: motion)
        cond.lock()
        if let s = liveStatusPromoting(job) { cond.unlock(); return s }
        cond.unlock()
        let stored = storedStatus(job)
        guard stored == .queued else { return stored }
        cond.lock(); defer { cond.unlock() }
        if let s = liveStatusPromoting(job) { return s }
        onDemand.append(job)
        startWorker()
        return .queued
    }

    /// Lock held. Like `liveStatus`, but a video waiting in the "Convert all" list jumps ahead.
    private func liveStatusPromoting(_ job: Job) -> VideoStatus? {
        if !job.motion, !onDemand.contains(job), running?.job != job, let i = allList.firstIndex(of: job.id) {
            allList.remove(at: i)
            promoted.insert(job.id)
            onDemand.append(job)
            startWorker()
        }
        return liveStatus(job)
    }

    /// Lock held.
    private func liveStatus(_ job: Job) -> VideoStatus? {
        if let r = running, r.job == job, r.cancelled == nil { return .converting(r.progress) }
        if onDemand.contains(job) || (!job.motion && allList.contains(job.id)) { return .queued }
        return nil
    }

    /// From disk and the catalog, ignoring the queue.
    private func storedStatus(_ job: Job) -> VideoStatus {
        if exists(output(job)) { return .ready }
        if job.motion {
            cond.lock()
            let failure = motionFailures[job.id]
            cond.unlock()
            if let failure { return .failed(failure) }
            guard ffmpeg != nil, (try? db.writer.read({ try MotionRow.fetchOne($0, key: job.id) })) != nil else { return .unavailable }
            return .queued
        }
        guard let a = try? db.writer.read({ try Asset.fetchOne($0, key: job.id) }), a.kind == "video" else { return .unavailable }
        if a.servePlan != "preview" { return .ready }
        if let e = a.videoError { return .failed(e) }
        return ffmpeg == nil ? .unavailable : .queued
    }

    // MARK: - Convert all

    public func startAll() {
        guard ffmpeg != nil else { return }
        let ids = ((try? db.writer.read { d in
            try String.fetchAll(d, sql: """
                SELECT id FROM asset WHERE kind = 'video' AND servePlan = 'preview' AND missingSince IS NULL ORDER BY takenAt DESC
                """)
        }) ?? []).filter { !exists(previewURL(id: $0)) }
        cond.lock(); defer { cond.unlock() }
        guard runState != "running" else { return }
        allList = ids
        done = 0
        total = ids.count
        runState = ids.isEmpty ? "idle" : "running"
        if !ids.isEmpty { startWorker() }
    }

    /// Stops "Convert all": the running "Convert all" conversion is killed (an on-demand one finishes).
    public func pause() {
        cond.lock(); defer { cond.unlock() }
        guard runState == "running" else { return }
        allList.removeAll()
        promoted.removeAll()
        if let r = running, r.fromAll { cancel(r, .discard) }
        runState = "paused"
    }

    public func allState() -> ConvertAllState {
        let needed = ((try? db.writer.read { d in
            try String.fetchAll(d, sql: "SELECT id FROM asset WHERE kind = 'video' AND servePlan = 'preview' AND missingSince IS NULL")
        }) ?? []).filter { !exists(previewURL(id: $0)) }.count
        var converted = 0
        var bytes: Int64 = 0
        for url in files() where url.pathExtension == "mp4" && !url.lastPathComponent.contains(".tmp.") {
            if !url.lastPathComponent.hasSuffix(".motion.mp4") { converted += 1 }
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        cond.lock(); defer { cond.unlock() }
        let current = running.flatMap { $0.forAll && $0.cancelled == nil ? $0 : nil }
        return ConvertAllState(state: runState, done: done, total: total,
                               current: current.map { $0.name ?? $0.job.id }, progress: current?.progress,
                               needed: needed, converted: converted, bytes: bytes, ffmpeg: ffmpeg != nil)
    }

    // MARK: - Cache maintenance

    /// Forgets an asset (purged): drops it from the queue, stops its conversion and deletes its previews.
    public func remove(id: String) {
        cond.lock(); defer { cond.unlock() }
        onDemand.removeAll { $0.id == id }
        allList.removeAll { $0 == id }
        promoted.remove(id)
        if let r = running, r.job.id == id { cancel(r, .discard) }
        motionFailures[id] = nil
        try? FileManager.default.removeItem(at: previewURL(id: id))
        try? FileManager.default.removeItem(at: motionPreviewURL(id: id))
    }

    /// Deletes every preview (Rebuild caches). A running conversion starts over.
    public func clear() throws {
        cond.lock(); defer { cond.unlock() }
        if let r = running { cancel(r, .requeue) }
        motionFailures.removeAll()
        if exists(videoDir) { try FileManager.default.removeItem(at: videoDir) }
    }

    /// Lock held.
    private func cancel(_ r: Running, _ how: Cancel) {
        // A discarded job (paused or removed) is never brought back by a later requeue.
        if how == .discard || r.cancelled == nil { r.cancelled = how }
        if let p = r.process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    // MARK: - Worker

    /// Lock held. The worker exits when the queue is empty and is started again by the next request.
    private func startWorker() {
        guard !workerActive else { return }
        workerActive = true
        let t = Thread { [self] in work() }
        t.name = "video-conversions"
        t.qualityOfService = .utility
        t.start()
    }

    private func work() {
        while true {
            cond.lock()
            let r: Running
            if !onDemand.isEmpty {
                let job = onDemand.removeFirst()
                r = Running(job: job, fromAll: false, counted: !job.motion && promoted.remove(job.id) != nil)
            } else if !allList.isEmpty {
                r = Running(job: Job(id: allList.removeFirst(), motion: false), fromAll: true)
            } else {
                workerActive = false
                cond.unlock()
                return
            }
            running = r
            cond.unlock()
            autoreleasepool { convert(r) }
            cond.lock()
            running = nil
            switch r.cancelled {
            case .requeue:
                if r.fromAll { allList.insert(r.job.id, at: 0) } else { onDemand.insert(r.job, at: 0) }
                if r.counted { promoted.insert(r.job.id) }
            case .discard:
                break
            case nil:
                if r.forAll {
                    done += 1
                    if allList.isEmpty && promoted.isEmpty && runState == "running" { runState = "idle" }
                }
            }
            cond.unlock()
        }
    }

    private struct Source { let url: URL; let width: Int; let height: Int; let hdr: Bool; let duration: Double }

    /// Nil when there is nothing to do (already converted, gone, or a failed video asked for on demand).
    private func source(_ r: Running) throws -> Source? {
        let id = r.job.id
        if r.job.motion {
            guard let url = try catalog.motionURL(id: id) else { throw ConversionError("Motion clip not found") }
            guard let p = VideoProbe.probe(url: url) else { throw ConversionError("Unreadable motion clip") }
            return Source(url: url, width: p.width, height: p.height, hdr: p.hdr, duration: p.duration)
        }
        guard let a = try db.writer.read({ try Asset.fetchOne($0, key: id) }), a.kind == "video",
              a.servePlan == "preview", r.forAll || a.videoError == nil else { return nil }
        guard let url = try catalog.sourceURL(id: id) else { throw ConversionError("Original file not found") }
        return Source(url: url, width: a.width, height: a.height, hdr: a.videoHDR, duration: a.duration ?? 0)
    }

    private struct ConversionError: Error { let message: String; init(_ m: String) { message = m } }

    private func convert(_ r: Running) {
        let out = output(r.job)
        guard let ffmpeg, !exists(out) else { return }
        let src: Source
        do {
            guard let s = try source(r) else { return }
            src = s
        } catch {
            fail(r, (error as? ConversionError)?.message ?? "\(error)")
            return
        }
        let base = out.deletingPathExtension()
        let tmp = base.appendingPathExtension("tmp.mp4")
        let log = base.appendingPathExtension("tmp.log")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: log)
        }

        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = Self.arguments(source: src.url, output: tmp, width: src.width, height: src.height, hdr: src.hdr)
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        let lastOutput = Stamp()
        let lines = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            lastOutput.touch()
            for line in lines.append(data) {
                guard let progress = Self.progress(line: line, duration: src.duration), let self else { continue }
                self.cond.lock(); r.progress = progress; self.cond.unlock()
            }
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }

        onLaunch?()
        cond.lock()
        r.name = src.url.lastPathComponent
        if r.cancelled != nil { cond.unlock(); return }
        do {
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let err = try FileHandle(forWritingTo: log)
            p.standardError = err
            defer { try? err.close() }
            try p.run()
        } catch {
            cond.unlock()
            fail(r, "Could not start ffmpeg: \(error.localizedDescription)")
            return
        }
        r.process = p
        cond.unlock()
        lastOutput.touch()

        var stalled = false
        let tick = min(0.25, stallTimeout)
        while exited.wait(timeout: .now() + tick) == .timedOut {
            if lastOutput.age >= stallTimeout {
                stalled = true
                kill(p.processIdentifier, SIGKILL)
                exited.wait()
                break
            }
        }

        cond.lock()
        r.process = nil
        if r.cancelled != nil { cond.unlock(); return }
        var failure: String?
        if stalled {
            failure = "Conversion stalled"
        } else if p.terminationStatus != 0 || !exists(tmp) {
            let detail = (try? String(contentsOf: log, encoding: .utf8))?
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? "ffmpeg exited with status \(p.terminationStatus)"
            failure = "Conversion failed: \(detail)"
        } else {
            do {
                try? FileManager.default.removeItem(at: out)
                try FileManager.default.moveItem(at: tmp, to: out)
            } catch {
                failure = "Could not save the preview: \(error.localizedDescription)"
            }
        }
        cond.unlock()
        if let failure { fail(r, failure) } else { succeeded(r) }
    }

    private func fail(_ r: Running, _ message: String) {
        if r.job.motion {
            cond.lock(); motionFailures[r.job.id] = message; cond.unlock()
        } else {
            try? db.writer.write {
                try $0.execute(sql: "UPDATE asset SET videoError = ? WHERE id = ?", arguments: [message, r.job.id])
            }
        }
    }

    private func succeeded(_ r: Running) {
        if r.job.motion {
            cond.lock(); motionFailures[r.job.id] = nil; cond.unlock()
        } else {
            try? db.writer.write {
                try $0.execute(sql: "UPDATE asset SET videoError = NULL WHERE id = ? AND videoError IS NOT NULL", arguments: [r.job.id])
            }
        }
    }
}
