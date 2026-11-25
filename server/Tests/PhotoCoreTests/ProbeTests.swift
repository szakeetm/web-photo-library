import Testing
import Foundation
@testable import PhotoCore

@Suite struct ProbeTests {
    @Test func hashKnownBytes() throws {
        let url = Fixtures.tempDir().appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: url)
        #expect(try FileHasher.sha256(url: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func hashLargerThanChunk() throws {
        let url = Fixtures.tempDir().appendingPathComponent("big.bin")
        try Data(repeating: 0x61, count: 3 * 1024 * 1024 + 5).write(to: url)
        // sha256 of 3 MiB + 5 bytes of "a", computed independently with shasum
        let expected = "aff2c7498aae939dfb2fb1dc6c0c83fa3708b069428e51338801af7f5dc2bf0f"
        #expect(try FileHasher.sha256(url: url) == expected)
    }

    @Test func probeReadsExif() throws {
        let url = Fixtures.tempDir().appendingPathComponent("e.jpg")
        Fixtures.writeJPEG(to: url, dateTimeOriginal: "2021:07:04 15:30:00", offset: "+02:00", gps: (47.5, 19.04))
        let p = try #require(ImageProbe.probe(url: url))
        #expect(p.width == 800 && p.height == 600)
        #expect(p.mime == "public.jpeg")
        #expect(p.exifOffset == 7200)
        #expect(p.exifDate == ISO8601DateFormatter().date(from: "2021-07-04T13:30:00Z"))
        #expect(p.exifLocalDate?.year == 2021 && p.exifLocalDate?.hour == 15)
        #expect(abs((p.lat ?? 0) - 47.5) < 1e-6 && abs((p.lon ?? 0) - 19.04) < 1e-6)
    }

    @Test func probeSouthWestGPS() throws {
        let url = Fixtures.tempDir().appendingPathComponent("sw.jpg")
        Fixtures.writeJPEG(to: url, gps: (-33.9, -70.6))
        let p = try #require(ImageProbe.probe(url: url))
        #expect(abs((p.lat ?? 0) + 33.9) < 1e-6 && abs((p.lon ?? 0) + 70.6) < 1e-6)
        #expect(p.exifDate == nil && p.exifLocalDate == nil)
    }

    @Test func probeOrientation6SwapsDims() throws {
        let url = Fixtures.tempDir().appendingPathComponent("r.jpg")
        Fixtures.writeJPEG(to: url, orientation: 6)
        let p = try #require(ImageProbe.probe(url: url))
        #expect(p.width == 600 && p.height == 800 && p.orientation == 6)
    }

    @Test func probeGarbageReturnsNil() throws {
        let dir = Fixtures.tempDir()
        try Data().write(to: dir.appendingPathComponent("x.jpg"))
        try Data("not an image".utf8).write(to: dir.appendingPathComponent("y.jpg"))
        #expect(ImageProbe.probe(url: dir.appendingPathComponent("x.jpg")) == nil)
        #expect(ImageProbe.probe(url: dir.appendingPathComponent("y.jpg")) == nil)
    }
}
