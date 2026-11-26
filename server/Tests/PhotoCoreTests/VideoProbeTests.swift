import Testing
import Foundation
import ImageIO
@testable import PhotoCore

@Suite struct VideoProbeTests {
    @Test func iso6709() {
        let a = VideoProbe.parseISO6709("+38.2451+021.7381+025.034/")
        #expect(a?.lat == 38.2451 && a?.lon == 21.7381)
        let b = VideoProbe.parseISO6709("-33.8688+151.2093/")
        #expect(b?.lat == -33.8688 && b?.lon == 151.2093)
        #expect(VideoProbe.parseISO6709("garbage") == nil)
    }

    @Test func quickTimeDates() {
        let a = VideoProbe.parseQuickTimeDate("2022-10-02T01:12:19+0300")
        #expect(a?.0 == Date(timeIntervalSince1970: 1664662339))
        #expect(a?.1 == 10800)
        #expect(VideoProbe.parseQuickTimeDate("2024-08-03T07:53:00+02:00")?.1 == 7200)
    }

    @Test func servePlans() {
        #expect(VideoProbe.servePlan(codec: "hevc", ext: "mov", width: 3840, height: 2160) == "preview")
        #expect(VideoProbe.servePlan(codec: "h264", ext: "mov", width: 1920, height: 1080) == "original")
        #expect(VideoProbe.servePlan(codec: "vp9", ext: "mov", width: 1920, height: 1080) == "preview")
        #expect(VideoProbe.servePlan(codec: "hevc", ext: "mp4", width: 1080, height: 1920) == "original")
        #expect(VideoProbe.servePlan(codec: "h264", ext: "avi", width: 640, height: 480) == "preview")
    }

    @Test func safariPlayable() {
        #expect(VideoProbe.safariPlayable(codec: "h264", ext: "MOV"))
        #expect(VideoProbe.safariPlayable(codec: "hevc", ext: "m4v"))
        #expect(!VideoProbe.safariPlayable(codec: "vp9", ext: "mp4"))
        #expect(!VideoProbe.safariPlayable(codec: "h264", ext: "mkv"))
        #expect(!VideoProbe.safariPlayable(codec: nil, ext: "mov"))
        #expect(VideoProbe.safariPlayable(codec: "h264", ext: "mov", h264Only: true))
        #expect(!VideoProbe.safariPlayable(codec: "hevc", ext: "mov", h264Only: true))
    }

    @Test func probeReadsFixture() async throws {
        let url = Fixtures.tempDir().appendingPathComponent("a.mov")
        try await Fixtures.writeVideo(to: url, width: 1280, height: 720, seconds: 2, contentId: "ABC",
                                      creationDate: "2024-08-03T07:53:00+02:00", location: "+47.4979+019.0402/")
        let r = try #require(VideoProbe.probe(url: url))
        #expect(r.width == 1280 && r.height == 720)
        #expect(abs(r.duration - 2) < 0.1)
        #expect(r.codec == "h264")
        #expect(r.contentId == "ABC")
        #expect(r.tzOffset == 7200)
        #expect(abs((r.lat ?? 0) - 47.4979) < 0.0001)
    }

    @Test func rotatedVideoReportsDisplaySize() async throws {
        let url = Fixtures.tempDir().appendingPathComponent("r.mov")
        try await Fixtures.writeVideo(to: url, width: 1280, height: 720, rotate90: true)
        let r = try #require(VideoProbe.probe(url: url))
        #expect(r.width == 720 && r.height == 1280)
    }

    @Test func appleContentId() {
        let id = "EF20AAAA-1111-2222-3333-444455556666"
        #expect(ImageProbe.appleContentId([kCGImagePropertyMakerAppleDictionary: ["17": id]]) == id)
        #expect(ImageProbe.appleContentId([:]) == nil)
    }

    @Test func locateFindsHomebrewFirst() {
        let both: Set<String> = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        #expect(FFmpeg.locate(environment: ["PATH": "/x/bin"], exists: { both.contains($0) })?.path == "/opt/homebrew/bin/ffmpeg")
        #expect(FFmpeg.locate(environment: ["PATH": "/y:/x/bin"], exists: { $0 == "/x/bin/ffmpeg" })?.path == "/x/bin/ffmpeg")
        #expect(FFmpeg.locate(environment: ["PATH": "/x/bin"], exists: { _ in false }) == nil)
        #expect(FFmpeg.ffprobe(next: URL(fileURLWithPath: "/x/bin/ffmpeg")).path == "/x/bin/ffprobe")
    }

    @Test(.enabled(if: FFmpeg.locate() != nil)) func ffprobeFallbackReadsVP9() throws {
        let ff = try #require(FFmpeg.locate())
        let url = Fixtures.tempDir().appendingPathComponent("v.webm")
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=1", "-c:v", "libvpx-vp9", url.path]
        try p.run(); p.waitUntilExit()
        let r = try #require(VideoProbe.probe(url: url))
        #expect(r.codec == "vp9" && r.width == 320 && r.height == 240)
    }

    /// A re-encoded copy (Google Photos) has no Apple creation date, only the movie header's.
    @Test func headerCreationTimeWhenNoAppleDate() throws {
        func probe(_ tags: String) -> VideoProbeResult? {
            VideoProbe.parseFFprobe(Data("""
                {"streams":[{"codec_type":"video","codec_name":"h264","width":1080,"height":1920}],
                 "format":{"duration":"10.1","tags":{\(tags)}}}
                """.utf8))
        }
        let google = try #require(probe(#""creation_time":"2024-04-07T03:30:26.000000Z""#))
        #expect(google.takenAt == ISO8601DateFormatter().date(from: "2024-04-07T03:30:26Z") && google.tzOffset == nil)
        // Apple's date (with its zone) wins
        let iphone = try #require(probe(#""creation_time":"2024-04-07T03:30:27.000000Z","com.apple.quicktime.creationdate":"2024-04-07T12:30:26+0900""#))
        #expect(iphone.takenAt == ISO8601DateFormatter().date(from: "2024-04-07T03:30:26Z") && iphone.tzOffset == 9 * 3600)
        // an unset header date isn't a date
        #expect(probe(#""creation_time":"1970-01-01T00:00:00.000000Z""#)?.takenAt == nil)
    }
}

