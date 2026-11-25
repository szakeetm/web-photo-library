import Foundation
import AVFoundation
import ImageIO

/// A representative still of a video, used as its thumbnail and preview.
public enum VideoPoster {
    /// AVFoundation at min(1s, duration/2) with rotation applied; ffmpeg when AVFoundation cannot decode the file.
    /// Blocks: call it off the cooperative thread pool.
    public static func frame(source: URL, ffmpeg: URL?) throws -> CGImage {
        if let img = avFrame(source: source) { return img }
        if let ffmpeg, let img = ffmpegFrame(source: source, ffmpeg: ffmpeg) { return img }
        throw DerivativeError.unreadableSource(source.path)
    }

    private final class Box: @unchecked Sendable { var value: CGImage? }

    private static func avFrame(source: URL) -> CGImage? {
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = try? await loadFrame(source: source)
            sem.signal()
        }
        sem.wait()
        return box.value
    }

    private static func loadFrame(source: URL) async throws -> CGImage? {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return nil }
        let duration = try await asset.load(.duration).seconds
        let t = duration.isFinite && duration > 0 ? min(1.0, duration / 2) : 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    private static func ffmpegFrame(source: URL, ffmpeg: URL) -> CGImage? {
        // The duration is unknown here: try half a second in, then the first frame (clips shorter than that).
        for ss in ["0.5", "0"] {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("poster-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let p = Process()
            p.executableURL = ffmpeg
            p.arguments = ["-v", "error", "-y", "-ss", ss, "-i", source.path, "-frames:v", "1", "-f", "image2", tmp.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            if p.terminationStatus == 0, let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                return img
            }
        }
        return nil
    }
}
