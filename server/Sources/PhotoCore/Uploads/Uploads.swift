import Foundation
import CryptoKit

public enum UploadError: Error, Equatable, CustomStringConvertible {
    case tooLarge, notConfigured, notAnImage
    public var description: String {
        switch self {
        case .tooLarge: "The file is too large."
        case .notConfigured: "No uploads folder is configured. Choose one in Settings."
        case .notAnImage: "Only photos can be uploaded."
        }
    }
}

public enum UploadSource: String, Sendable {
    case phone, desktop
}

/// Receives one uploaded file into `<uploads>/.incoming/`, hashing while writing.
/// Nothing outside `.incoming` is touched until `UploadPlacer.place` moves the finished file.
public final class UploadSession: @unchecked Sendable {
    public struct Result: Sendable { public let tempURL: URL; public let sha256: String; public let size: Int64 }

    public let tempURL: URL
    private let handle: FileHandle
    private var hasher = SHA256()
    private var size: Int64 = 0
    private let maxBytes: Int64
    private var closed = false

    public init(uploadsRoot: URL, maxBytes: Int64 = 512 << 20) throws {
        let incoming = uploadsRoot.appendingPathComponent(".incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        tempURL = incoming.appendingPathComponent("\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        handle = try FileHandle(forWritingTo: tempURL)
        self.maxBytes = maxBytes
    }

    public func write(_ data: Data) throws {
        size += Int64(data.count)
        if size > maxBytes {
            abort()
            throw UploadError.tooLarge
        }
        hasher.update(data: data)
        try handle.write(contentsOf: data)
    }

    public func finish() throws -> Result {
        try handle.synchronize()
        try handle.close()
        closed = true
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Result(tempURL: tempURL, sha256: hex, size: size)
    }

    /// Discards the partial file.
    public func abort() {
        if !closed { try? handle.close(); closed = true }
        try? FileManager.default.removeItem(at: tempURL)
    }

    /// Removes leftovers of interrupted uploads (e.g. after a crash).
    public static func cleanIncoming(uploadsRoot: URL) {
        let incoming = uploadsRoot.appendingPathComponent(".incoming")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? [] where name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: incoming.appendingPathComponent(name))
        }
    }
}

/// Moves a received file to `<source>-uploads/YYYY-MM/<name>` (capture month, local time), never overwriting.
public enum UploadPlacer {
    private static let lock = NSLock()

    public static func place(temp: URL, uploadsRoot: URL, source: UploadSource, name: String,
                             takenAt: Date, tzOffset: Int?) throws -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: tzOffset ?? 0) ?? TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month], from: takenAt)
        let dirRel = "\(source.rawValue)-uploads/" + String(format: "%04d-%02d", c.year ?? 1970, c.month ?? 1)
        let dir = uploadsRoot.appendingPathComponent(dirRel, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let clean = sanitize(name)
        let ext = (clean as NSString).pathExtension
        let stem = (clean as NSString).deletingPathExtension
        lock.lock(); defer { lock.unlock() }
        var candidate = clean
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            n += 1
        }
        try FileManager.default.moveItem(at: temp, to: dir.appendingPathComponent(candidate))
        return dirRel + "/" + candidate
    }

    /// Last path component only, no leading dots or control characters.
    static func sanitize(_ name: String) -> String {
        var base = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        base = String(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
        while base.hasPrefix(".") { base.removeFirst() }
        return base.isEmpty ? "upload" : base
    }
}
