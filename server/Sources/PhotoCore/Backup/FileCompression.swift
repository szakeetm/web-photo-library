import Compression
import Foundation

/// Files compressed with LZFSE, the compression built into macOS (no tool to install): about half the
/// size for the database, at ~200 MB/s. Streams a megabyte at a time, so a large database is never in
/// memory whole. The result is a plain LZFSE stream: `compression_tool -decode -a lzfse` reads it on any
/// Mac, and the open-source lzfse tool elsewhere.
enum FileCompression {
    static let suffix = ".lzfse"

    static func compress(_ src: URL, to dst: URL) throws { try run(.compress, src, dst) }
    static func decompress(_ src: URL, to dst: URL) throws { try run(.decompress, src, dst) }

    private static func run(_ op: FilterOperation, _ src: URL, _ dst: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        guard fm.createFile(atPath: dst.path, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dst.path]) }
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let filter = try OutputFilter(op, using: .lzfse) { data in
            if let data { try out.write(contentsOf: data) }
        }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try filter.write(chunk)
        }
        try filter.finalize()
    }
}
