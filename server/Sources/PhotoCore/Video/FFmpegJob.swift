import Foundation

/// The ffmpeg command line and its `-progress` output, for VideoConversions.
extension VideoConversions {
    /// HEVC (VideoToolbox) MP4 for Safari: short side scaled to 1080 when larger, HLG kept as 10-bit HDR.
    /// `width`/`height` are the display size; ffmpeg autorotates before the scale filter.
    static func arguments(source: URL, output: URL, width: Int, height: Int, hdr: Bool) -> [String] {
        var a = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path,
                 "-map", "0:v:0", "-map", "0:a:0?"]
        if min(width, height) > 1080 {
            a += ["-vf", width <= height ? "scale=1080:-2" : "scale=-2:1080"]
        }
        a += ["-c:v", "hevc_videotoolbox", "-b:v", "4M", "-tag:v", "hvc1"]
        a += hdr
            ? ["-profile:v", "main10", "-pix_fmt", "p010le", "-color_primaries", "bt2020",
               "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc"]
            : ["-pix_fmt", "yuv420p"]
        a += ["-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", "-map_metadata", "-1",
              "-progress", "pipe:1", "-nostats", output.path]
        return a
    }

    /// Fraction done from one `-progress` line (`out_time_us=…`).
    static func progress(line: String, duration: Double) -> Double? {
        guard duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) else { return nil }
        return min(1, max(0, us / 1_000_000 / duration))
    }
}

/// When ffmpeg last wrote progress.
final class Stamp: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    var age: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}

/// Splits pipe output into lines across reads.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    func append(_ data: Data) -> [String] {
        pending.append(data)
        guard let end = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = pending[pending.startIndex...end]
        pending = Data(pending[(end + 1)...])
        return String(decoding: complete, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
}
