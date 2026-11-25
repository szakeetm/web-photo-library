import Foundation
import AVFoundation
import CoreMedia

public struct VideoProbeResult: Sendable, Equatable {
    public var width: Int            // display width (rotation applied)
    public var height: Int           // display height (rotation applied)
    public var duration: Double
    public var codec: String         // "h264" | "hevc" | "vp9" | ...
    public var hdr: Bool             // HLG or PQ transfer
    public var takenAt: Date?
    public var tzOffset: Int?        // seconds east of UTC
    public var lat: Double?
    public var lon: Double?
    public var make: String?
    public var model: String?
    public var contentId: String?    // Apple Live Photo id (com.apple.quicktime.content.identifier)
}

public enum VideoProbe {
    /// AVFoundation first; ffprobe when AVFoundation cannot read the tracks (e.g. VP9).
    public static func probe(url: URL) -> VideoProbeResult? {
        if let r = probeAVFoundation(url: url) { return r }
        return probeFFprobe(url: url)
    }

    /// "original" when the file plays natively in browsers (h264/hevc in mov/mp4/m4v, short side <= 1080), else "preview".
    public static func servePlan(codec: String, ext: String, width: Int, height: Int) -> String {
        safariPlayable(codec: codec, ext: ext) && min(width, height) <= 1080 ? "original" : "preview"
    }

    /// Safari plays H.264/HEVC in QuickTime/MP4 containers.
    public static func safariPlayable(codec: String?, ext: String) -> Bool {
        ["h264", "hevc"].contains(codec?.lowercased() ?? "") && ["mov", "mp4", "m4v"].contains(ext.lowercased())
    }

    /// "+38.2451+021.7381+025.034/" → (38.2451, 21.7381)
    public static func parseISO6709(_ s: String) -> (lat: Double, lon: Double)? {
        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s),
              let lat = Double(s[a]), let lon = Double(s[b]),
              abs(lat) <= 90, abs(lon) <= 180
        else { return nil }
        return (lat, lon)
    }

    /// "2022-10-02T01:12:19+0300" or "...+03:00" → (instant, seconds east of UTC)
    public static func parseQuickTimeDate(_ s: String) -> (Date, Int)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssxx", "yyyy-MM-dd'T'HH:mm:ssxxx"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            if let d = f.date(from: t), let off = offsetSeconds(of: t) { return (d, off) }
        }
        return nil
    }

    private static func offsetSeconds(of s: String) -> Int? {
        guard let i = s.lastIndex(where: { $0 == "+" || $0 == "-" }), i > s.index(s.startIndex, offsetBy: 10) else { return nil }
        let digits = s[s.index(after: i)...].filter(\.isNumber)
        guard digits.count == 4, let h = Int(digits.prefix(2)), let m = Int(digits.suffix(2)) else { return nil }
        let secs = h * 3600 + m * 60
        return s[i] == "-" ? -secs : secs
    }

    // MARK: AVFoundation

    private static func probeAVFoundation(url: URL) -> VideoProbeResult? {
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = try? await loadAV(url: url)
            sem.signal()
        }
        sem.wait()
        return box.value
    }

    private final class ResultBox: @unchecked Sendable { var value: VideoProbeResult? }

    private static func loadAV(url: URL) async throws -> VideoProbeResult? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return nil }
        let (size, transform, descs) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let w = Int(abs(rect.width).rounded()), h = Int(abs(rect.height).rounded())
        guard w > 0, h > 0, let desc = descs.first else { return nil }
        let duration = try await asset.load(.duration).seconds

        let codec = codecName(CMFormatDescriptionGetMediaSubType(desc))
        var hdr = false
        if let tf = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
            hdr = tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                || tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        }

        var r = VideoProbeResult(width: w, height: h, duration: duration.isFinite ? duration : 0, codec: codec, hdr: hdr)
        let items = try await asset.load(.metadata)
        func string(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
            return try? await item.load(.stringValue)
        }
        r.contentId = await string(.quickTimeMetadataContentIdentifier)
        r.make = await string(.quickTimeMetadataMake)
        r.model = await string(.quickTimeMetadataModel)
        if let s = await string(.quickTimeMetadataCreationDate), let (d, off) = parseQuickTimeDate(s) {
            r.takenAt = d; r.tzOffset = off
        }
        if let s = await string(.quickTimeMetadataLocationISO6709), let ll = parseISO6709(s) {
            r.lat = ll.lat; r.lon = ll.lon
        }
        return r
    }

    private static func codecName(_ fourCC: FourCharCode) -> String {
        switch fourCC {
        case kCMVideoCodecType_H264: return "h264"
        case kCMVideoCodecType_HEVC: return "hevc"
        case 0x76703039: return "vp9"   // 'vp09'
        case 0x61763031: return "av1"   // 'av01'
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((fourCC >> UInt32($0)) & 0xFF) }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    // MARK: ffprobe

    private static func probeFFprobe(url: URL) -> VideoProbeResult? {
        guard let ffmpeg = FFmpeg.locate() else { return nil }
        let p = Process()
        p.executableURL = FFmpeg.ffprobe(next: ffmpeg)
        p.arguments = ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return parseFFprobe(data)
    }

    static func parseFFprobe(_ data: Data) -> VideoProbeResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]],
              let v = streams.first(where: { ($0["codec_type"] as? String) == "video" }),
              let pw = (v["width"] as? NSNumber)?.intValue, let ph = (v["height"] as? NSNumber)?.intValue,
              pw > 0, ph > 0
        else { return nil }
        let format = root["format"] as? [String: Any] ?? [:]
        let tags = (format["tags"] as? [String: Any] ?? [:]).reduce(into: [String: String]()) {
            if let s = $1.value as? String { $0[$1.key.lowercased()] = s }
        }

        var rotation = 0
        for sd in v["side_data_list"] as? [[String: Any]] ?? [] {
            if let r = (sd["rotation"] as? NSNumber)?.intValue { rotation = r }
        }
        let swap = abs(rotation) % 180 == 90
        let duration = Double((format["duration"] as? String) ?? (v["duration"] as? String) ?? "") ?? 0
        let transfer = v["color_transfer"] as? String
        var r = VideoProbeResult(
            width: swap ? ph : pw, height: swap ? pw : ph, duration: duration,
            codec: (v["codec_name"] as? String) ?? "", hdr: transfer == "arib-std-b67" || transfer == "smpte2084")
        r.contentId = tags["com.apple.quicktime.content.identifier"]
        r.make = tags["com.apple.quicktime.make"]
        r.model = tags["com.apple.quicktime.model"]
        if let s = tags["com.apple.quicktime.creationdate"], let (d, off) = parseQuickTimeDate(s) {
            r.takenAt = d; r.tzOffset = off
        }
        if let s = tags["com.apple.quicktime.location.iso6709"] ?? tags["location"], let ll = parseISO6709(s) {
            r.lat = ll.lat; r.lon = ll.lon
        }
        return r
    }
}
