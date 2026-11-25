import Foundation

/// Which source the running server was built from: the git commit of the checkout it runs from
/// (override with PHOTOSERVER_COMMIT / PHOTOSERVER_COMMIT_DATE, e.g. for a packaged app).
public struct BuildInfo: Sendable, Encodable {
    public let commit: String?
    /// ISO-8601 commit date.
    public let commitDate: String?
    /// The checkout had uncommitted changes to tracked files when the server started.
    public let dirty: Bool

    public static let current = detect()

    static func detect() -> BuildInfo {
        let env = ProcessInfo.processInfo.environment
        if let c = env["PHOTOSERVER_COMMIT"], !c.isEmpty {
            return BuildInfo(commit: c, commitDate: env["PHOTOSERVER_COMMIT_DATE"], dirty: false)
        }
        let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        guard let log = git(["log", "-1", "--format=%h%n%cI"], in: sourceDir) else {
            return BuildInfo(commit: nil, commitDate: nil, dirty: false)
        }
        let parts = log.split(separator: "\n").map(String.init)
        // only the server's own sources count (Sources/PhotoAPI → ../.. is server/)
        let status = git(["status", "--porcelain", "--untracked-files=no", "--", "../.."], in: sourceDir) ?? ""
        return BuildInfo(commit: parts.first, commitDate: parts.count > 1 ? parts[1] : nil, dirty: !status.isEmpty)
    }

    static func git(_ args: [String], in dir: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var label: String {
        guard let commit else { return "unknown build" }
        return commit + (dirty ? "+local changes" : "") + (commitDate.map { " (\($0))" } ?? "")
    }
}
