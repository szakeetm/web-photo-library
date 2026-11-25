import Foundation
import CoreImage
import ImageIO

/// A photo's HDR gain map in one simple form for the edit pipeline (browser and server alike),
/// whatever the original's format (Apple's or ISO 21496-1): one byte per pixel, orientation applied,
/// where a value v means "this pixel is 2^(v/255 × stops) brighter than its SDR value".
///
/// It is measured rather than parsed: ImageIO decodes the photo once as SDR and once as HDR (gain map
/// applied) and the map is the luminance ratio, so both formats and all their parameters are covered.
public struct NormalizedGainMap: Sendable, Equatable {
    public var pixels: [UInt8]
    public var width: Int
    public var height: Int
    /// Gain of a 255 pixel, in stops (log2 of the photo's headroom).
    public var stops: Float

    public var headroom: Float { exp2(stops) }

    /// Long edge of the map the editor and previews use.
    public static let previewMaxPixel = 1024

    /// Nil when the photo has no gain map (or one that never brightens anything).
    public static func make(source: URL, maxPixel: Int) throws -> NormalizedGainMap? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { throw DerivativeError.unreadableSource(source.path) }
        guard !GainMap.all(in: src).isEmpty else { return nil }
        func decode(hdr: Bool) -> CGImage? {
            var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCacheImmediately: true]
            if hdr { opts[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        guard let sdr = decode(hdr: false), let hdr = decode(hdr: true), sdr.width == hdr.width, sdr.height == hdr.height else {
            throw DerivativeError.unreadableSource(source.path)
        }
        let stops = log2(max(hdr.contentHeadroom, 1))
        guard stops > 0.05 else { return nil }
        let w = sdr.width, h = sdr.height
        let ys = luminance(sdr, w, h), yh = luminance(hdr, w, h)
        // Darks carry little signal (and ISO maps add small offsets there): a floor keeps them calm.
        let floor: Float = 0.02
        var pixels = [UInt8](repeating: 0, count: w * h)
        var any = false
        for i in 0..<(w * h) {
            let g = log2((yh[i] + floor) / (ys[i] + floor)) / stops
            let v = UInt8((min(max(g, 0), 1) * 255).rounded())
            pixels[i] = v
            if v > 2 { any = true }
        }
        return any ? NormalizedGainMap(pixels: pixels, width: w, height: h, stops: stops) : nil
    }

    /// Linear Display-P3 luminance, extended range (Core Image keeps values above 1).
    private static func luminance(_ image: CGImage, _ w: Int, _ h: Int) -> [Float] {
        var px = [Float](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        GainMap.measureContext.render(CIImage(cgImage: image), toBitmap: &px, rowBytes: w * 16,
                                      bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: space)
        var y = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { y[i] = max(0, 0.2289746 * px[i * 4] + 0.6917385 * px[i * 4 + 1] + 0.0792869 * px[i * 4 + 2]) }
        return y
    }

    // MARK: Wire format (GET /api/gainmap/:id)

    /// "GMP1", width, height (UInt32 LE), stops (Float32 LE), then the pixels as raw DEFLATE.
    public func encoded() throws -> Data {
        var d = Data("GMP1".utf8)
        withUnsafeBytes(of: UInt32(width).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(height).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: stops.bitPattern.littleEndian) { d.append(contentsOf: $0) }
        d.append(try (Data(pixels) as NSData).compressed(using: .zlib) as Data)
        return d
    }

    public static func decode(_ d: Data) throws -> NormalizedGainMap {
        let bytes = [UInt8](d)
        guard bytes.count >= 16, bytes[0..<4] == [0x47, 0x4D, 0x50, 0x31] else { throw DerivativeError.unreadableSource("gain map") }
        func u32(_ o: Int) -> UInt32 { UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24 }
        let w = Int(u32(4)), h = Int(u32(8)), stops = Float(bitPattern: u32(12))
        let pixels = [UInt8](try (Data(bytes[16...]) as NSData).decompressed(using: .zlib) as Data)
        guard pixels.count == w * h else { throw DerivativeError.unreadableSource("gain map") }
        return NormalizedGainMap(pixels: pixels, width: w, height: h, stops: stops)
    }
}

extension GainMap {
    /// Float context without colour management of its own (inputs are tagged; output space given per call).
    static let measureContext = CIContext(options: [.cacheIntermediates: false])
}

extension HDRMetadata {
    /// The gain maps resized by `factor` (e.g. for a thumbnail made from a preview).
    func scaled(by factor: Double) -> HDRMetadata {
        guard factor < 0.999 else { return self }
        return HDRMetadata(gainMaps: gainMaps.compactMap { $0.transformed(orientation: .up, scale: factor, context: GainMap.context) },
                           imageProperties: imageProperties)
    }

    /// Gain map for an edited photo, computed by Core Image from its two renditions (the ratio of HDR to
    /// SDR). The SDR rendition stays the image written; only the map (and its metadata) is taken.
    static func derived(sdr: CGImage, hdr: CGImage) throws -> HDRMetadata {
        // The map is low resolution anyway: measure on at most 2048 px.
        let long = max(sdr.width, sdr.height)
        let s = min(1, 2048 / Double(long))
        let sdrCI = CIImage(cgImage: sdr).transformed(by: CGAffineTransform(scaleX: s, y: s))
        let hdrCI = CIImage(cgImage: hdr).transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let data = GainMap.measureContext.heifRepresentation(
            of: sdrCI, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            options: [.hdrImage: hdrCI]),
            let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DerivativeError.encodeFailed("HDR gain map")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        return HDRMetadata(gainMaps: GainMap.all(in: src), imageProperties: imageProperties(from: props))
    }
}

extension HDRMetadata {
    /// The original's own gain maps put through `recipe`'s geometry exactly like the image (same shader
    /// geometry), for edits that change nothing else: no gain map is recalculated.
    static func geometry(of source: URL, recipe: EditRecipe, renderer: EditRenderer) throws -> HDRMetadata {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { throw DerivativeError.unreadableSource(source.path) }
        let maps = GainMap.all(in: src)
        guard !maps.isEmpty else { return .none }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber).flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        let geometry = recipe.geometryOnly
        let out = try maps.compactMap { map -> GainMap? in
            guard let oriented = map.transformed(orientation: orientation, scale: 1, context: GainMap.context),
                  let data = oriented.info[kCGImageAuxiliaryDataInfoData] as? Data,
                  let desc = oriented.info[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any],
                  let rowBytes = (desc["BytesPerRow"] as? NSNumber)?.intValue else { return nil }
            let w = oriented.width, h = oriented.height
            var rgba = [UInt8](repeating: 255, count: w * h * 4)
            data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for y in 0..<h { for x in 0..<w {
                    let v = b[y * rowBytes + x]
                    let o = (y * w + x) * 4
                    rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v
                } }
            }
            let r = try renderer.render(rgba: rgba, width: w, height: h, recipe: geometry)
            let outRow = (r.width + 15) & ~15
            var bytes = Data(count: outRow * r.height)
            bytes.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
                for y in 0..<r.height { for x in 0..<r.width { b[y * outRow + x] = r.pixels[(y * r.width + x) * 4] } }
            }
            var info = oriented.info
            info[kCGImageAuxiliaryDataInfoData] = bytes
            info[kCGImageAuxiliaryDataInfoDataDescription] = [
                "Width": r.width, "Height": r.height, "BytesPerRow": outRow, "PixelFormat": GainMap.oneComponent8,
            ] as [String: Any]
            return GainMap(type: oriented.type, info: info)
        }
        return HDRMetadata(gainMaps: out, imageProperties: imageProperties(from: props))
    }
}
