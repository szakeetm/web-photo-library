import Foundation
import Hummingbird
import HTTPTypes

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
func fileResponse(path: String, contentType: String, request: Request, context: BasicRequestContext,
                  extraHeaders: HTTPFields = [:]) async throws -> Response {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = (attrs[.size] as? NSNumber)?.intValue else { throw HTTPError(.notFound) }
    var headers = extraHeaders
    headers[.acceptRanges] = "bytes"
    headers[.contentType] = contentType
    let fileIO = FileIO()
    switch ByteRange(header: request.headers[.range], size: size) {
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
