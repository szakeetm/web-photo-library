import Testing
import Foundation
@preconcurrency import AVFoundation
import GRDB
@testable import PhotoCore

@Suite struct VideoTrimTests {
    @Test func cutsWithoutReencodingAndKeepsTheDate() async throws {
        let dir = Fixtures.tempDir()
        let src = dir.appendingPathComponent("clip.mov")
        try await Fixtures.writeVideo(to: src, width: 320, height: 240, seconds: 4, creationDate: "2021-07-04T15:30:00+0200")
        let out = dir.appendingPathComponent("cut.mov")
        let date = ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z")!
        try await VideoCutter.cut(source: src, start: 1, end: 3, to: out, creationDate: date, tzOffset: 3600, ffmpeg: nil)
        let asset = AVURLAsset(url: out)
        let seconds = try await asset.load(.duration).seconds
        #expect(abs(seconds - 2) < 0.2)
        let probe = try #require(VideoProbe.probe(url: out))
        #expect(probe.takenAt == date && probe.tzOffset == 3600)
    }

    @Test func filmstripHasFrames() async throws {
        let src = Fixtures.tempDir().appendingPathComponent("clip.mov")
        try await Fixtures.writeVideo(to: src, width: 320, height: 240, seconds: 2)
        let data = try await VideoCutter.filmstrip(source: src, duration: 2, count: 4, height: 60)
        let image = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.height == 60 && image.width == 4 * 80)
    }

    @Test func storesAndValidatesTrims() throws {
        let db = try AppDatabase.inMemory()
        let id = String(repeating: "a", count: 64)
        try db.writer.write { d in
            var a = Asset.placeholder(id: id)
            a.kind = "video"; a.duration = 10
            try a.insert(d)
        }
        let s = VideoTrimService(db: db)
        try s.set(id: id, start: 2, end: 20)  // clamped to the end
        #expect(try s.trim(id: id)! == (2, 10))
        #expect(throws: TrimError.self) { try s.set(id: id, start: 5, end: 5.2) }
        try s.set(id: id, start: 0, end: 10)  // the whole video: no trim
        #expect(try s.trim(id: id) == nil)
    }
}
