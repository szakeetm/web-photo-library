import Foundation

public enum RcloneError: Error, CustomStringConvertible {
    case notInstalled
    case failed(String)
    case notFound(String)
    /// stopped because the job it was for was cancelled
    case cancelled

    public var description: String {
        switch self {
        case .cancelled: "Stopped."

        case .notInstalled: "rclone isn't installed (brew install rclone), or the server can't find it."
        case .failed(let m): m
        case .notFound(let p): "Not found: \(p)"
        }
    }
}

/// rclone processes running for this server, so they can be stopped when it shuts down or restarts
/// (otherwise a scan's download carries on without it).
public enum RcloneProcesses {
    nonisolated(unsafe) private static var running: [ObjectIdentifier: Process] = [:]
    private static let lock = NSLock()
    static func add(_ p: Process) { lock.lock(); running[ObjectIdentifier(p)] = p; lock.unlock() }
    static func remove(_ p: Process) { lock.lock(); running[ObjectIdentifier(p)] = nil; lock.unlock() }
    /// Stops every rclone this server started.
    public static func terminateAll() {
        lock.lock(); let all = Array(running.values); running = [:]; lock.unlock()
        for p in all where p.isRunning { p.terminate() }
    }
}

/// The rclone command line (https://rclone.org), for any remote it has been set up with
/// (`rclone config`): pCloud, S3, SFTP… A path is "remote:dir/sub", or a local path.
public struct Rclone: Sendable {
    public let binary: URL

    public init(binary: URL) { self.binary = binary }

    /// rclone on this Mac: $RCLONE, Homebrew, /usr/local/bin or the PATH.
    public static func locate() -> Rclone? {
        let env = ProcessInfo.processInfo.environment
        var candidates = [env["RCLONE"], "/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"].compactMap { $0 }
        candidates += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/rclone" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { Rclone(binary: URL(fileURLWithPath: $0)) }
    }

    /// Network flags: give up on a stalled connection instead of hanging.
    static let netFlags = ["--contimeout", "20s", "--timeout", "2m", "--retries", "3", "--low-level-retries", "10"]

    /// Runs rclone; throws with its error message when it fails. `line` hears each line it logs.
    ///
    /// Its output goes to temporary files, not pipes: a process started meanwhile (ffmpeg, another
    /// rclone) inherits open pipe ends, and waiting for a pipe to end would then wait for that
    /// process too.
    @discardableResult
    /// Runs rclone; `line` hears each line it logs. When `isCancelled` turns true, rclone is stopped
    /// and `RcloneError.cancelled` thrown.
    public func run(_ args: [String], line: ((String) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) throws -> Data {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("rclone-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        let outW = try FileHandle(forWritingTo: outURL), errW = try FileHandle(forWritingTo: errURL)
        p.standardOutput = outW
        p.standardError = errW
        p.standardInput = FileHandle.nullDevice
        try p.run()
        RcloneProcesses.add(p)
        defer { RcloneProcesses.remove(p) }
        try? outW.close()
        try? errW.close()

        // follow the log while it runs
        let errR = try FileHandle(forReadingFrom: errURL)
        defer { try? errR.close() }
        var log = "", pending = Data()
        func drain(final: Bool) {
            if let chunk = try? errR.readToEnd(), !chunk.isEmpty { pending.append(chunk) }
            while let nl = pending.firstIndex(of: 0x0A) {
                let text = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                log += text + "\n"
                line?(text)
            }
            if final, !pending.isEmpty {
                let text = String(decoding: pending, as: UTF8.self)
                log += text
                line?(text)
                pending.removeAll()
            }
        }
        while p.isRunning {
            Thread.sleep(forTimeInterval: line == nil ? 0.05 : 0.25)
            if line != nil { drain(final: false) }
            if isCancelled?() == true {
                p.terminate()
                p.waitUntilExit()
                throw RcloneError.cancelled
            }
        }
        p.waitUntilExit()
        drain(final: true)
        guard p.terminationStatus == 0 else {
            let message = Self.message(log)
            if message.localizedCaseInsensitiveContains("directory not found") || message.localizedCaseInsensitiveContains("object not found") {
                throw RcloneError.notFound(args.last ?? "")
            }
            throw RcloneError.failed(message.isEmpty ? "rclone failed (\(p.terminationStatus))." : message)
        }
        return (try? Data(contentsOf: outURL)) ?? Data()
    }

    /// The last error rclone logged, without its timestamp.
    static func message(_ log: String) -> String {
        let lines = log.split(separator: "\n").map(String.init)
        let picked = lines.last { $0.contains("ERROR") || $0.contains("Failed") || $0.contains("CRITICAL") } ?? lines.last ?? ""
        if let r = picked.range(of: #"(ERROR|NOTICE|CRITICAL)\s*:\s*"#, options: .regularExpression) { return String(picked[r.upperBound...]) }
        return picked
    }

    // MARK: Browsing

    /// The remotes set up in rclone ("pcloud:", "s3:"…).
    public func remotes() throws -> [String] {
        String(decoding: try run(["listremotes"]), as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Folders directly inside `path`, sorted.
    public func folders(_ path: String) throws -> [String] {
        let out = try run(["lsf", "--dirs-only", "--max-depth", "1"] + Self.netFlags + [path])
        return String(decoding: out, as: UTF8.self).split(separator: "\n")
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : String($0) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func makeFolder(_ path: String) throws { try run(["mkdir"] + Self.netFlags + [path]) }

    public struct Entry: Decodable, Sendable {
        public let Path: String
        public let Size: Int64
        public let IsDir: Bool
    }

    /// The file or folder at `path`; nil when there is none.
    public func stat(_ path: String) throws -> Entry? {
        do {
            return try JSONDecoder().decode(Entry.self, from: try run(["lsjson", "--stat"] + Self.netFlags + [path]))
        } catch RcloneError.notFound { return nil }
    }

    /// Which of `files` (paths relative to `dir`) are there, with their sizes, in one listing.
    public func sizes(in dir: String, files: [String]) throws -> [String: Int64] {
        guard !files.isEmpty else { return [:] }
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("rclone-files-\(UUID().uuidString).txt")
        try files.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        let out = try run(["lsjson", "-R", "--files-only", "--no-mimetype", "--files-from-raw", list.path] + Self.netFlags + [dir])
        return Dictionary(try JSONDecoder().decode([Entry].self, from: out).map { ($0.Path, $0.Size) }, uniquingKeysWith: { a, _ in a })
    }

    /// A file in a remote folder, for scanning it.
    public struct RemoteFile: Sendable, Equatable {
        public let path: String
        public let size: Int64
        /// seconds since 1970
        public let mtime: Double
    }

    /// Every file under `path` (recursively), in one listing.
    public func files(_ path: String) throws -> [RemoteFile] {
        struct E: Decodable { let Path: String; let Size: Int64; let ModTime: String }
        let out = try run(["lsjson", "-R", "--files-only", "--no-mimetype", "--fast-list"] + Self.netFlags + [path])
        return try JSONDecoder().decode([E].self, from: out).compactMap { e in
            Self.date(e.ModTime).map { RemoteFile(path: e.Path, size: e.Size, mtime: $0) }
        }
    }

    /// rclone's times ("2019-12-24T16:27:45Z", "2026-11-26T13:55:22.123456789+01:00"), to the millisecond.
    static func date(_ s: String) -> Double? {
        var t = s
        if let r = t.range(of: #"\.(\d{1,9})"#, options: .regularExpression) {
            let digits = t[r].dropFirst()
            t.replaceSubrange(r, with: "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = t.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.date(from: t)?.timeIntervalSince1970
    }

    /// Copies `files` (paths relative to `from`) into `to`, keeping their paths and modification times.
    /// `copied` hears each file as it arrives (its path within `from`); a cancelled copy stops at once.
    public func copyFiles(_ files: [String], from: String, to: String, transfers: Int = 32,
                          isCancelled: (() -> Bool)? = nil, copied: ((String) -> Void)? = nil) throws {
        guard !files.isEmpty else { return }
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("rclone-files-\(UUID().uuidString).txt")
        try files.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        var onLine: ((String) -> Void)?
        if let copied {
            onLine = { line in
                // "2026/11/26 13:01:02 INFO  : Library/a.jpg: Copied (new)"
                guard line.contains(": Copied ("), let r = line.range(of: "INFO  : ") else { return }
                let rest = line[r.upperBound...]
                copied(rest.range(of: ": Copied (").map { String(rest[..<$0.lowerBound]) } ?? String(rest))
            }
        }
        let args = ["copy", "-v", "--stats", "0", "--files-from-raw", list.path, "--transfers", String(transfers),
                    "--checkers", String(transfers), "--no-traverse"] + Self.netFlags + [from, to]
        _ = try run(args, line: onLine, isCancelled: isCancelled)
    }

    public struct Size: Decodable, Sendable {
        public let count: Int
        public let bytes: Int64
    }

    /// Files and bytes under `path` (zero when it doesn't exist).
    public func size(_ path: String) throws -> Size {
        do { return try JSONDecoder().decode(Size.self, from: try run(["size", "--json"] + Self.netFlags + [path])) } catch RcloneError.notFound {
            return Size(count: 0, bytes: 0)
        }
    }

    public func read(_ path: String) throws -> Data { try run(["cat"] + Self.netFlags + [path]) }

    // MARK: Copying

    /// One file, to exactly `to` (a remote path or a local one).
    public func copyFile(_ from: String, to: String) throws { try run(["copyto"] + Self.netFlags + [from, to]) }

    /// Files in `from` missing or different in `to` (never deletes anything); `copied` hears each file
    /// copied. Hidden files and folders are skipped. Returns how many were copied.
    @discardableResult
    public func copyFolder(_ from: String, to: String, transfers: Int = 8, copied: (@Sendable (String) -> Void)? = nil) throws -> Int {
        let count = LockedBox(0)
        try run(["copy", "-v", "--transfers", String(transfers), "--exclude", ".*", "--exclude", ".*/**", "--stats", "0"]
                + Self.netFlags + [from, to]) { line in
            // "2026/11/26 13:01:02 INFO  : phone-uploads/a.jpg: Copied (new)"
            guard line.contains(": Copied ("), let r = line.range(of: "INFO  : ") else { return }
            let rest = line[r.upperBound...]
            let file = rest.range(of: ": Copied (").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            count.mutate { $0 += 1 }
            copied?(file)
        }
        return count.value
    }

    /// Makes `to` the same as `from`: copies what's missing or different and deletes what isn't in
    /// `from` any more (hidden files and folders are left out on both sides). Returns how many files
    /// were copied and deleted.
    @discardableResult
    public func syncFolder(_ from: String, to: String, transfers: Int = 8,
                           copied: (@Sendable (String) -> Void)? = nil) throws -> (copied: Int, deleted: Int) {
        let n = LockedBox((0, 0))
        try run(["sync", "-v", "--transfers", String(transfers), "--exclude", ".*", "--exclude", ".*/**", "--stats", "0"]
                + Self.netFlags + [from, to]) { line in
            guard let r = line.range(of: "INFO  : ") else { return }
            let rest = line[r.upperBound...]
            if let c = rest.range(of: ": Copied (") {
                n.mutate { $0.0 += 1 }
                copied?(String(rest[..<c.lowerBound]))
            } else if rest.hasSuffix(": Deleted") {
                n.mutate { $0.1 += 1 }
            }
        }
        return n.value
    }

    /// Joins a remote folder and a name ("pcloud:" + "a" → "pcloud:a", "pcloud:x" + "a" → "pcloud:x/a").
    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix(":") || dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}

/// A value shared between threads.
public final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
