@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

public enum TrimError: Error, CustomStringConvertible {
    case invalid(String)
    case notAVideo
    case failed(String)
    public var description: String {
        switch self {
        case .invalid(let s): s
        case .notAVideo: "Only videos can be trimmed."
        case .failed(let s): "Trimming failed: \(s)"
        }
    }
}

/// Video trims: kept in the database (`video_trim`), applied when playing and when exporting. The
/// library's files are never changed; "Save as New" writes a trimmed copy into the uploads folder.
public final class VideoTrimService: Sendable {
    /// Shortest clip a trim may leave.
    public static let minLength = 0.5

    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Checks a range against the video's duration (it is clamped to the end).
    public func validated(id: String, start: Double, end: Double) throws -> (Double, Double) {
        let asset = try db.writer.read { try Asset.fetchOne($0, key: id) }
        guard let asset, asset.kind == "video", let duration = asset.duration else { throw TrimError.notAVideo }
        let s = max(0, start), e = min(duration, end)
        guard s.isFinite, e.isFinite, e - s >= Self.minLength else { throw TrimError.invalid("The trimmed clip is too short.") }
        return (s, e)
    }

    /// Sets the trim; the whole video (or nearly) removes it.
    public func set(id: String, start: Double, end: Double) throws {
        let (s, e) = try validated(id: id, start: start, end: end)
        let duration = try db.writer.read { try Double.fetchOne($0, sql: "SELECT duration FROM asset WHERE id = ?", arguments: [id]) } ?? e
        try db.writer.write { d in
            if s < 0.05 && duration - e < 0.05 {
                try d.execute(sql: "DELETE FROM video_trim WHERE assetId = ?", arguments: [id])
            } else {
                try d.execute(sql: "INSERT OR REPLACE INTO video_trim (assetId, start, \"end\", createdAt) VALUES (?, ?, ?, ?)",
                              arguments: [id, s, e, Date()])
            }
            try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
        }
    }

    public func revert(id: String) throws {
        try db.writer.write { d in
            try d.execute(sql: "DELETE FROM video_trim WHERE assetId = ?", arguments: [id])
            try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
        }
    }

    public func trim(id: String) throws -> (start: Double, end: Double)? {
        try db.writer.read { d in
            try Row.fetchOne(d, sql: "SELECT start, \"end\" FROM video_trim WHERE assetId = ?", arguments: [id]).map { ($0["start"], $0["end"]) }
        }
    }
}

/// Cutting and previewing videos without re-encoding.
public enum VideoCutter {
    /// File types AVFoundation writes without re-encoding.
    static func fileType(_ ext: String) -> AVFileType? {
        switch ext.lowercased() {
        case "mov", "qt": .mov
        case "mp4": .mp4
        case "m4v": .m4v
        default: nil
        }
    }

    /// Writes `[start, end]` of `source` to `output` without re-encoding (AVFoundation passthrough, or
    /// ffmpeg's stream copy for containers AVFoundation can't write). With `creationDate`, the copy
    /// carries that date (adjusted dates), in the time zone `tzOffset` when known.
    public static func cut(source: URL, start: Double, end: Double, to output: URL, creationDate: Date? = nil,
                           tzOffset: Int? = nil, ffmpeg: URL?) async throws {
        let stamp = creationDate.map { d -> String in
            let f = ISO8601DateFormatter()
            f.timeZone = TimeZone(secondsFromGMT: tzOffset ?? 0) ?? TimeZone(identifier: "UTC")!
            return f.string(from: d)
        }
        try? FileManager.default.removeItem(at: output)
        if let type = fileType(source.pathExtension), fileType(output.pathExtension) == type {
            let asset = AVURLAsset(url: source)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw TrimError.failed("this video can't be exported")
            }
            let timescale: CMTimeScale = 600
            session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: timescale),
                                            end: CMTime(seconds: end, preferredTimescale: timescale))
            var metadata = (try? await asset.load(.metadata)) ?? []
            if let creationDate {
                metadata.removeAll { $0.identifier == .commonIdentifierCreationDate || $0.identifier == .quickTimeMetadataCreationDate }
                let item = AVMutableMetadataItem()
                item.identifier = type == .mov ? .quickTimeMetadataCreationDate : .commonIdentifierCreationDate
                item.value = (stamp ?? ISO8601DateFormatter().string(from: creationDate)) as NSString
                item.dataType = kCMMetadataBaseDataType_UTF8 as String
                metadata.append(item)
            }
            session.metadata = metadata
            do {
                try await session.export(to: output, as: type)
            } catch {
                throw TrimError.failed(error.localizedDescription)
            }
            return
        }
        guard let ffmpeg else { throw TrimError.failed("this video format needs ffmpeg (brew install ffmpeg)") }
        var args = ["-nostdin", "-y", "-ss", String(format: "%.3f", start), "-to", String(format: "%.3f", end),
                    "-i", source.path, "-map", "0", "-c", "copy", "-map_metadata", "0"]
        if let creationDate { args += ["-metadata", "creation_time=\(ISO8601DateFormatter().string(from: creationDate))"] }
        args.append(output.path)
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        let tail = err.fileHandleForReading.readDataToEndOfFile().suffix(400)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TrimError.failed(String(decoding: tail, as: UTF8.self)) }
    }

    /// `count` frames across the video side by side in one JPEG (the trim editor's filmstrip).
    public static func filmstrip(source: URL, duration: Double, count: Int, height: Int = 120) async throws -> Data {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: height * 4, height: height)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var frames: [CGImage] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let (image, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) { frames.append(image) }
            else if let last = frames.last { frames.append(last) }
        }
        guard let first = frames.first else { throw TrimError.failed("no frames") }
        let w = max(1, Int(Double(first.width) * Double(height) / Double(max(1, first.height))))
        let ctx = CGContext(data: nil, width: w * frames.count, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for (i, f) in frames.enumerated() { ctx.draw(f, in: CGRect(x: i * w, y: 0, width: w, height: height)) }
        let data = NSMutableData()
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw TrimError.failed("filmstrip")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TrimError.failed("filmstrip") }
        return data as Data
    }
}
