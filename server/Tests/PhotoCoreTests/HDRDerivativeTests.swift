import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCore

/// Thumbnails and previews of HDR (gain-map) photos keep the original's SDR pixels and carry its gain map.
@Suite struct HDRDerivativeTests {
    static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// A gain-map HEIC (made by ImageIO's encoder from an HDR image) whose stored top-left quadrant is
    /// 4× brighter than SDR white and the rest mid grey, saved with EXIF `orientation`.
    static func writeHDR(to url: URL, width: Int = 1200, height: Int = 800, orientation: Int = 1) throws {
        var px = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v: Float = (x < width / 2 && y < height / 2) ? 4 : 0.2
                let o = (y * width + x) * 4
                px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 1
            }
        }
        let data = Data(bytes: px, count: px.count * 4) as CFData
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let flat = try #require(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                                        space: Self.linearP3, bitmapInfo: info, provider: CGDataProvider(data: data)!,
                                        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        // Without a declared headroom the encoder treats the image as SDR and makes no gain map worth having.
        let img = try #require(CGImageCreateCopyWithContentHeadroom(4, flat))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyOrientation: orientation,
                                               kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    static func gainMapTypes(_ url: URL) -> [String] {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return GainMap.all(in: s).map { $0.type as String }
    }

    /// Linear luminance at the centres of the four quadrants (TL, TR, BL, BR) of the oriented image,
    /// decoded in HDR (gain map applied) or SDR.
    static func quadrants(_ url: URL, hdr: Bool) throws -> [Float] {
        let img = try #require(CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: hdr]))
        let w = 64, h = 64
        let scaled = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
        var px = [Float](repeating: 0, count: w * h * 4)
        CIContext().render(scaled, toBitmap: &px, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBAf, colorSpace: Self.linearP3)
        // Core Image bitmaps run top row first.
        return [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)].map { x, y in px[(y * w + x) * 4 + 1] }
    }

    @Test func previewAndThumbKeepGainMap() throws {
        let dir = Fixtures.tempDir()
        let src = dir.appendingPathComponent("hdr.heic")
        try Self.writeHDR(to: src)
        #expect(!Self.gainMapTypes(src).isEmpty)
        let store = DerivativeStore(cacheDir: dir.appendingPathComponent("cache"))
        let (thumb, preview) = try store.ensureAll(id: "abcdef", source: src, format: .heic)
        let jpeg = try store.ensure(id: "abcdef", source: src, kind: .preview, format: .jpeg)
        for url in [thumb, preview, jpeg] {
            #expect(Self.gainMapTypes(url) == Self.gainMapTypes(src), "\(url.lastPathComponent)")
            let q = try Self.quadrants(url, hdr: true)
            #expect(q[0] > 2, "\(url.lastPathComponent) highlights shown above SDR white: \(q)")
            #expect(q[3] < 0.5, "\(url.lastPathComponent) shadows unchanged: \(q)")
        }
    }

    @Test func sdrPixelsMatchOriginal() throws {
        let dir = Fixtures.tempDir()
        let src = dir.appendingPathComponent("hdr.heic")
        try Self.writeHDR(to: src)
        let store = DerivativeStore(cacheDir: dir.appendingPathComponent("cache"))
        let preview = try store.ensure(id: "abcdef", source: src, kind: .preview, format: .heic)
        let a = try Self.quadrants(src, hdr: false), b = try Self.quadrants(preview, hdr: false)
        for i in 0..<4 { #expect(abs(a[i] - b[i]) < 0.02, "SDR \(a) vs \(b)") }
    }

    @Test(arguments: [3, 6, 8])
    func gainMapFollowsOrientation(orientation: Int) throws {
        let dir = Fixtures.tempDir()
        let src = dir.appendingPathComponent("hdr.heic")
        try Self.writeHDR(to: src, orientation: orientation)
        let store = DerivativeStore(cacheDir: dir.appendingPathComponent("cache"))
        let (thumb, preview) = try store.ensureAll(id: "abcdef", source: src, format: .heic)
        let expected = try Self.quadrants(src, hdr: true)
        let bright = expected.firstIndex(of: expected.max()!)!
        for url in [preview, thumb] {
            let q = try Self.quadrants(url, hdr: true)
            #expect(q.firstIndex(of: q.max()!) == bright && q[bright] > 2, "orientation \(orientation): \(expected) vs \(q)")
        }
    }

    @Test func sdrSourceHasNoGainMap() throws {
        let dir = Fixtures.tempDir()
        let src = dir.appendingPathComponent("src.jpg")
        Fixtures.writeJPEG(to: src)
        let store = DerivativeStore(cacheDir: dir.appendingPathComponent("cache"))
        let preview = try store.ensure(id: "abcdef", source: src, kind: .preview, format: .heic)
        #expect(Self.gainMapTypes(preview).isEmpty)
    }

    /// Apple's (pre-ISO) gain maps need the headroom maker-note tags; nothing else from the maker note is copied.
    @Test func appleHeadroomTagsCopied() {
        let props: [CFString: Any] = [kCGImagePropertyMakerAppleDictionary: [33: "0.99", 48: "-0.02", 17: "uuid", 2: Data([1])] as [AnyHashable: Any]]
        let out = HDRMetadata.imageProperties(from: props)[kCGImagePropertyMakerAppleDictionary] as? [AnyHashable: Any]
        #expect(Set((out ?? [:]).keys.map { "\($0)" }) == ["33", "48"])
        #expect(HDRMetadata.imageProperties(from: [:]).isEmpty)
    }

    @Test func upgradeClearsOlderRevisionOnce() throws {
        let dir = Fixtures.tempDir()
        let src = dir.appendingPathComponent("src.jpg")
        Fixtures.writeJPEG(to: src)
        let store = DerivativeStore(cacheDir: dir.appendingPathComponent("cache"))
        let old = try store.ensure(id: "abcdef", source: src, kind: .thumb, format: .heic)
        try store.upgradeIfNeeded()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let new = try store.ensure(id: "abcdef", source: src, kind: .thumb, format: .heic)
        try store.upgradeIfNeeded()
        #expect(FileManager.default.fileExists(atPath: new.path))
    }
}
