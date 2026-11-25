import Foundation

public enum FFmpeg {
    /// First executable `ffmpeg`: Homebrew (Apple silicon), Homebrew (Intel), then each PATH entry.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        var candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            candidates.append("\(dir)/ffmpeg")
        }
        return candidates.first(where: exists).map { URL(fileURLWithPath: $0) }
    }

    /// `ffprobe` lives next to `ffmpeg`.
    public static func ffprobe(next ffmpeg: URL) -> URL {
        ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
    }
}
