import Foundation
import zlib

/// Writes a ZIP archive as it goes (nothing is held on disk or in memory): stored entries (photos
/// and videos don't compress), each followed by a data descriptor, ZIP64 throughout so archives and
/// files may exceed 4 GB. Readable by the Finder (Archive Utility), `unzip`, `ditto` and Windows.
public final class ZipStream {
    public typealias Sink = (Data) async throws -> Void

    struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt64
        let offset: UInt64
        let dosTime: UInt16
        let dosDate: UInt16
    }

    private let sink: Sink
    private var offset: UInt64 = 0
    private var entries: [Entry] = []
    static let chunk = 1 << 20

    public init(sink: @escaping Sink) { self.sink = sink }

    /// Bytes written so far.
    public var bytesWritten: UInt64 { offset }

    private func emit(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await sink(data)
        offset += UInt64(data.count)
    }

    /// Adds a file from disk, streamed in chunks.
    public func add(path: String, file: URL, modified: Date) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try await add(path: path, modified: modified) {
            try handle.read(upToCount: Self.chunk) ?? Data()
        }
    }

    /// Adds bytes held in memory (sidecars).
    public func add(path: String, data: Data, modified: Date) async throws {
        var sent = false
        try await add(path: path, modified: modified) {
            if sent { return Data() }
            sent = true
            return data
        }
    }

    private func add(path: String, modified: Date, next: () throws -> Data) async throws {
        let name = Data(path.utf8)
        let (time, date) = Self.dos(modified)
        let start = offset
        var header = Data()
        header.le32(0x0403_4b50)
        header.le16(45)                // version needed: ZIP64
        header.le16(0x0808)            // data descriptor follows; UTF-8 names
        header.le16(0)                 // stored
        header.le16(time)
        header.le16(date)
        header.le32(0)                 // crc (in the descriptor)
        header.le32(0xFFFF_FFFF)       // sizes: in the ZIP64 extra / descriptor
        header.le32(0xFFFF_FFFF)
        header.le16(UInt16(name.count))
        header.le16(20)                // extra length
        header.append(name)
        header.le16(0x0001)            // ZIP64 extra
        header.le16(16)
        header.le64(0)
        header.le64(0)
        try await emit(header)

        var crc: uLong = crc32(0, nil, 0)
        var size: UInt64 = 0
        while true {
            let data = try next()
            if data.isEmpty { break }
            crc = data.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            size += UInt64(data.count)
            try await emit(data)
        }

        var descriptor = Data()
        descriptor.le32(0x0807_4b50)
        descriptor.le32(UInt32(crc))
        descriptor.le64(size)
        descriptor.le64(size)
        try await emit(descriptor)
        entries.append(Entry(name: name, crc: UInt32(crc), size: size, offset: start, dosTime: time, dosDate: date))
    }

    /// Writes the central directory. Call once, after the last entry.
    public func finish() async throws {
        let cdStart = offset
        var cd = Data()
        for e in entries {
            cd.le32(0x0201_4b50)
            cd.le16(0x0300 | 45)        // made by: Unix, ZIP64
            cd.le16(45)
            cd.le16(0x0808)
            cd.le16(0)
            cd.le16(e.dosTime)
            cd.le16(e.dosDate)
            cd.le32(e.crc)
            cd.le32(0xFFFF_FFFF)
            cd.le32(0xFFFF_FFFF)
            cd.le16(UInt16(e.name.count))
            cd.le16(28)                 // extra length
            cd.le16(0)                  // comment
            cd.le16(0)                  // disk
            cd.le16(0)                  // internal attributes
            cd.le32(UInt32(0o100644) << 16)  // -rw-r--r--
            cd.le32(0xFFFF_FFFF)        // offset: in the ZIP64 extra
            cd.append(e.name)
            cd.le16(0x0001)
            cd.le16(24)
            cd.le64(e.size)
            cd.le64(e.size)
            cd.le64(e.offset)
        }
        try await emit(cd)
        let cdSize = UInt64(cd.count)
        let eocd64 = offset
        var end = Data()
        end.le32(0x0606_4b50)           // ZIP64 end of central directory
        end.le64(44)
        end.le16(0x0300 | 45)
        end.le16(45)
        end.le32(0)
        end.le32(0)
        end.le64(UInt64(entries.count))
        end.le64(UInt64(entries.count))
        end.le64(cdSize)
        end.le64(cdStart)
        end.le32(0x0706_4b50)           // ZIP64 locator
        end.le32(0)
        end.le64(eocd64)
        end.le32(1)
        end.le32(0x0605_4b50)           // end of central directory
        end.le16(0)
        end.le16(0)
        end.le16(UInt16(min(entries.count, 0xFFFF)))
        end.le16(UInt16(min(entries.count, 0xFFFF)))
        end.le32(UInt32(min(cdSize, 0xFFFF_FFFF)))
        end.le32(0xFFFF_FFFF)
        end.le16(0)
        try await emit(end)
    }

    /// MS-DOS time and date (local time), as ZIP stores them.
    static func dos(_ d: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let year = max(1980, min(2107, c.year ?? 1980))
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let date = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, date)
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le64(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
