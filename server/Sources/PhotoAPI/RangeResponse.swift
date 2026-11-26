import Foundation
import Hummingbird
import HTTPTypes
import PhotoCore

/// What a `Range` request header asks of a file of a known size.
enum ByteRange: Equatable {
    /// No header, a malformed one, or several ranges: the whole file (200).
    case full
    case partial(ClosedRange<Int>)
    /// Starts at or past the end of the file (416).
    case unsatisfiable

    /// Single ranges only: `bytes=a-b`, `bytes=a-` and the suffix form `bytes=-n`.
    init(header: String?, size: Int) {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else { self = .full; return }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard let dash = spec.firstIndex(of: "-") else { self = .full; return }
        let first = spec[..<dash], last = spec[spec.index(after: dash)...]
        if first.isEmpty {
            guard let n = Int(last), n >= 0 else { self = .full; return }
            self = n == 0 || size == 0 ? .unsatisfiable : .partial(max(0, size - n)...(size - 1))
            return
        }
        guard let start = Int(first), start >= 0 else { self = .full; return }
        let end: Int
        if last.isEmpty {
            end = size - 1
        } else {
            guard let e = Int(last), e >= start else { self = .full; return }
            end = min(e, size - 1)
        }
        self = start >= size ? .unsatisfiable : .partial(start...end)
    }
}

/// Streams a file, honouring a single byte range (Safari needs this to play video).
/// With `etag`, the response carries a validator from the file's size and mtime, answers a matching
/// `If-None-Match` with 304, and ignores a `Range` whose `If-Range` names another version.
func fileResponse(path: String, contentType: String, request: Request, context: BasicRequestContext,
                  extraHeaders: HTTPFields = [:], etag: Bool = false) async throws -> Response {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = (attrs[.size] as? NSNumber)?.intValue else { throw HTTPError(.notFound) }
    var headers = extraHeaders
    headers[.acceptRanges] = "bytes"
    headers[.contentType] = contentType
    var rangeHeader = request.headers[.range]
    if etag {
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let tag = "\"\(size)-\(Int64((mtime * 1000).rounded()))\""
        headers[.eTag] = tag
        if let inm = request.headers[.ifNoneMatch],
           inm.split(separator: ",").contains(where: { let t = $0.trimmingCharacters(in: .whitespaces); return t == tag || t == "W/" + tag || t == "*" }) {
            headers[.contentType] = nil
            return Response(status: .notModified, headers: headers)
        }
        if let ifRange = request.headers[.ifRange], ifRange != tag { rangeHeader = nil }
    }
    let fileIO = FileIO()
    switch ByteRange(header: rangeHeader, size: size) {
    case .full:
        return Response(status: .ok, headers: headers, body: try await fileIO.loadFile(path: path, context: context))
    case .partial(let range):
        headers[.contentRange] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
        return Response(status: .partialContent, headers: headers,
                        body: try await fileIO.loadFile(path: path, range: range, context: context))
    case .unsatisfiable:
        headers[.contentRange] = "bytes */\(size)"
        return Response(status: .rangeNotSatisfiable, headers: headers)
    }
}

extension OriginalStore {
    /// The original as a local file (fetched first, for a store that keeps it elsewhere), off the
    /// cooperative thread pool.
    func file(_ id: String) async throws -> URL? { try await blocking { try self.original(id: id) } }
    /// A Live Photo's motion clip as a local file, the same way.
    func motionFile(_ id: String) async throws -> URL? { try await blocking { try self.motion(id: id) } }
}
