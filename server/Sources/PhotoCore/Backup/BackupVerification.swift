import CryptoKit
import Foundation

// Checking that a backup arrived whole: the destination's own hashes of what was uploaded (pCloud
// computes SHA-256 and SHA-1 itself) against the same hashes computed here.

extension Rclone {
    /// The hash types the destination at `path` can report, by rclone's names ("sha256", "sha1"…).
    public func hashTypes(_ path: String) throws -> [String] {
        struct Features: Decodable { let Hashes: [String]? }
        return try JSONDecoder().decode(Features.self, from: try run(["backend", "features", path])).Hashes ?? []
    }

    /// The destination's `type` hash of the file at `path` (lowercase hex); nil when it has none.
    public func hash(_ path: String, type: String) throws -> String? {
        let out = String(decoding: try run(["hashsum", type] + Self.netFlags + [path]), as: UTF8.self)
        let h = out.split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() }
        return h.flatMap { $0.allSatisfy(\.isHexDigit) && !$0.isEmpty ? $0 : nil }
    }

    /// How many files of the local folder `from` are missing or different in `to`, compared by hash
    /// where both sides have one (by size otherwise). Hidden files are left out, as `syncFolder` does.
    public func differences(_ from: String, in to: String) throws -> Int {
        do {
            _ = try run(["check", "--one-way", "--exclude", ".*", "--exclude", ".*/**"] + Self.netFlags + [from, to])
            return 0
        } catch RcloneError.failed(let message) {
            // "ERROR : 2 differences found"
            guard let r = message.range(of: #"(\d+) differences? found"#, options: .regularExpression),
                  let n = Int(message[r].split(separator: " ")[0]) else { throw RcloneError.failed(message) }
            return n
        }
    }
}

enum LocalHash {
    /// The `type` hash ("sha256", "sha1", "md5") of a file here, read a megabyte at a time.
    static func hex(_ url: URL, type: String) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        func run<H: HashFunction>(_ hasher: inout H) throws -> String {
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        switch type {
        case "sha256": var x = SHA256(); return try run(&x)
        case "sha1": var x = Insecure.SHA1(); return try run(&x)
        case "md5": var x = Insecure.MD5(); return try run(&x)
        default: throw RcloneError.failed("Unsupported hash \(type)")
        }
    }

    /// The hashes preferred for checking a backup, strongest first, with their names for people.
    static let preferred: [(type: String, label: String)] = [("sha256", "SHA-256"), ("sha1", "SHA-1"), ("md5", "MD5")]
}

extension BackupService {
    /// Checks the files just uploaded are at the destination exactly as here: `files` (local file, name
    /// at the destination) by the destination's own hash, `uploads` folder file by file. Returns how it
    /// was checked ("SHA-256", or "size" where the destination has no hashes); throws when anything differs.
    func verify(_ rclone: Rclone, dest: String, files: [(local: URL, name: String)], uploads: String?) throws -> String {
        let offered = (try? rclone.hashTypes(dest)) ?? []
        let pick = LocalHash.preferred.first { offered.contains($0.type) }
        for f in files {
            let remote = Rclone.join(dest, f.name)
            if let pick {
                guard let theirs = try rclone.hash(remote, type: pick.type) else {
                    throw BackupError.notVerified("\(f.name): the destination gave no \(pick.label) for it.")
                }
                let ours = try LocalHash.hex(f.local, type: pick.type)
                guard theirs == ours else {
                    throw BackupError.notVerified("\(f.name) isn't the same at the destination (its \(pick.label) differs).")
                }
            } else {
                let size = ((try FileManager.default.attributesOfItem(atPath: f.local.path)[.size]) as? NSNumber)?.int64Value
                guard let entry = try rclone.stat(remote), entry.Size == size else {
                    throw BackupError.notVerified("\(f.name) isn't the same size at the destination.")
                }
            }
        }
        if let uploads {
            let n = try rclone.differences(uploads, in: Rclone.join(dest, "uploads"))
            guard n == 0 else { throw BackupError.notVerified("\(n) upload\(n == 1 ? "" : "s") missing or different at the destination.") }
        }
        return pick?.label ?? "size"
    }
}
