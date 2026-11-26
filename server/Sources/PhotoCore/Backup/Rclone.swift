import Foundation

public enum RcloneError: Error, CustomStringConvertible {
    case notInstalled
    case failed(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .notInstalled: "rclone isn't installed (brew install rclone), or the server can't find it."
        case .failed(let m): m
        case .notFound(let p): "Not found: \(p)"
        }
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
    public func run(_ args: [String], line: (@Sendable (String) -> Void)? = nil) throws -> Data {
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
        let out = try run(["lsjson", "--files-only", "--no-mimetype", "--files-from-raw", list.path] + Self.netFlags + [dir])
        return Dictionary(try JSONDecoder().decode([Entry].self, from: out).map { ($0.Path, $0.Size) }, uniquingKeysWith: { a, _ in a })
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
