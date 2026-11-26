import Foundation
import CryptoKit

public enum FileHasher {
    /// Streaming SHA-256 of a file's contents, lowercase hex.
    public static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.readChunk(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension FileHandle {
    /// `read(upToCount:)` in its own autorelease pool. Foundation hands back an autoreleased buffer, so a
    /// loop over a large file would otherwise keep every chunk until the surrounding pool drains.
    public func readChunk(upToCount count: Int) throws -> Data? {
        try autoreleasepool { try read(upToCount: count) }
    }
}
