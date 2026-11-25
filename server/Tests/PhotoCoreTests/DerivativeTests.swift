import Testing
import Foundation
import CoreGraphics
@testable import PhotoCore

@Suite struct DerivativeTests {
    func setup(width: Int = 4000, height: Int = 3000, orientation: Int? = nil) -> (DerivativeStore, URL) {
        let dir = Fixtures.tempDir()
        let src = dir.appendingPathComponent("src.jpg")
        Fixtures.writeJPEG(to: src, width: width, height: height, orientation: orientation)
        return (DerivativeStore(cacheDir: dir.appendingPathComponent("cache")), src)
    }

    @Test func thumbIsHeic512() throws {
        let (store, src) = setup()
        let url = try store.ensure(id: "abcdef", source: src, kind: .thumb, format: .heic)
        let p = try #require(ImageProbe.probe(url: url))
        #expect(p.mime == "public.heic" && max(p.width, p.height) == 512 && p.width == 512 && p.height == 384)
    }

    @Test func previewIs2048() throws {
        let (store, src) = setup()
        let url = try store.ensure(id: "abcdef", source: src, kind: .preview, format: .heic)
        #expect(ImageProbe.probe(url: url).map { max($0.width, $0.height) } == 2048)
    }

    @Test func smallSourceNotUpscaled() throws {
        let (store, src) = setup(width: 300, height: 200)
        let url = try store.ensure(id: "abcdef", source: src, kind: .preview, format: .heic)
        #expect(ImageProbe.probe(url: url).map { max($0.width, $0.height) } == 300)
    }

    @Test func jpegVariant() throws {
        let (store, src) = setup()
        let url = try store.ensure(id: "abcdef", source: src, kind: .thumb, format: .jpeg)
        #expect(ImageProbe.probe(url: url)?.mime == "public.jpeg")
    }

    @Test func orientationApplied() throws {
        let (store, src) = setup(width: 800, height: 600, orientation: 6)
        let url = try store.ensure(id: "abcdef", source: src, kind: .thumb, format: .heic)
        let p = try #require(ImageProbe.probe(url: url))
        #expect(p.width == 384 && p.height == 512 && p.orientation == 1)
    }

    @Test func cachePathLayout() {
        let store = DerivativeStore(cacheDir: URL(fileURLWithPath: "/c"))
        #expect(store.url(id: "abcdef", kind: .preview, editVersion: 2, format: .jpeg).path == "/c/preview/ab/abcdef_e2.jpeg")
    }

    @Test func ensureIsCachedAndClearable() throws {
        let (store, src) = setup()
        let u1 = try store.ensure(id: "abcdef", source: src, kind: .thumb, format: .heic)
        let m1 = try FileManager.default.attributesOfItem(atPath: u1.path)[.modificationDate] as! Date
        let u2 = try store.ensure(id: "abcdef", source: src, kind: .thumb, format: .heic)
        let m2 = try FileManager.default.attributesOfItem(atPath: u2.path)[.modificationDate] as! Date
        #expect(u1 == u2 && m1 == m2)
        #expect(store.sizeOnDisk() > 0)
        try store.clear()
        #expect(store.sizeOnDisk() == 0 && !FileManager.default.fileExists(atPath: u1.path))
    }

    @Test func concurrentEnsureSameKey() async throws {
        let (store, src) = setup()
        try await withThrowingTaskGroup(of: URL.self) { g in
            for _ in 0..<8 { g.addTask { try store.ensure(id: "abcdef", source: src, kind: .preview, format: .heic) } }
            for try await u in g { #expect(ImageProbe.probe(url: u) != nil) }
        }
    }

    @Test func unreadableSourceThrows() throws {
        let dir = Fixtures.tempDir()
        let bad = dir.appendingPathComponent("bad.jpg")
        try Data("x".utf8).write(to: bad)
        let store = DerivativeStore(cacheDir: dir.appendingPathComponent("cache"))
        #expect(throws: (any Error).self) { try store.ensure(id: "abcdef", source: bad, kind: .thumb, format: .heic) }
    }
}

@Suite struct BlurHashTests {
    func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        return ctx.makeImage()!
    }

    // Size flag 'L' = 4x3 components; the DC term (chars 2..<6) encodes the average sRGB colour.
    @Test func solidRedStructure() {
        let h = Array(BlurHash.encode(cgImage: solid(1, 0, 0)))
        #expect(h[0] == "L")
        let dc = h[2..<6].reduce(0) { $0 * 83 + BlurHash.chars.firstIndex(of: $1)! }
        #expect(dc == 0xFF0000)
    }

    @Test func differentImagesDiffer() {
        #expect(BlurHash.encode(cgImage: solid(1, 0, 0)) != BlurHash.encode(cgImage: solid(0, 0, 1)))
    }

    @Test func lengthFor4x3() {
        #expect(BlurHash.encode(cgImage: solid(0.2, 0.5, 0.7)).count == 28)
    }
}
