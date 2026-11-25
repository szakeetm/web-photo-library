import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum DerivativeKind: String, Sendable, CaseIterable {
    case thumb, preview
    public var maxPixel: Int { self == .thumb ? 512 : 2048 }
}

public enum ImageFormat: String, Sendable, CaseIterable {
    case heic, jpeg
    var utType: UTType { self == .heic ? .heic : .jpeg }
    var quality: Double { self == .heic ? 0.6 : 0.8 }
    public var mimeType: String { self == .heic ? "image/heic" : "image/jpeg" }
}

public enum DerivativeError: Error, CustomStringConvertible {
    case unreadableSource(String)
    case encodeFailed(String)
    public var description: String {
        switch self {
        case .unreadableSource(let p): "Cannot decode image: \(p)"
        case .encodeFailed(let p): "Cannot encode derivative: \(p)"
        }
    }
}

/// Thumbnails and previews on disk: cache/{kind}/{id[0:2]}/{id}_e{edit}.{fmt}
public final class DerivativeStore: @unchecked Sendable {
    public let cacheDir: URL
    /// Fixed lock stripes: generation of the same key is serialised without an ever-growing lock table.
    private let stripes = (0..<64).map { _ in NSLock() }

    /// Bumped when derivatives change how they look (2: HDR gain maps). Clients send it in image URLs
    /// (`r=`), since those are cached as immutable; a store made by an older build is cleared on start.
    public static let revision = 2

    public init(cacheDir: URL) { self.cacheDir = cacheDir }

    /// Clears thumbnails and previews made by an older revision (they're regenerated on demand).
    public func upgradeIfNeeded() throws {
        let marker = cacheDir.appendingPathComponent("derivatives-revision")
        if let r = try? String(contentsOf: marker, encoding: .utf8), Int(r.trimmingCharacters(in: .whitespacesAndNewlines)) == Self.revision { return }
        try clear()
        // Exports of edits are SDR before revision 2.
        let exports = cacheDir.appendingPathComponent("exports")
        if FileManager.default.fileExists(atPath: exports.path) { try FileManager.default.removeItem(at: exports) }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try String(Self.revision).write(to: marker, atomically: true, encoding: .utf8)
    }

    public func url(id: String, kind: DerivativeKind, editVersion: Int = 0, format: ImageFormat) -> URL {
        cacheDir.appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(String(id.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(id)_e\(editVersion).\(format.rawValue)")
    }

    /// Returns the derivative, generating it from `source` (unedited) if missing.
    @discardableResult
    public func ensure(id: String, source: URL, kind: DerivativeKind, editVersion: Int = 0, format: ImageFormat) throws -> URL {
        let target = url(id: id, kind: kind, editVersion: editVersion, format: format)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let keyLock = lockFor(target.path)
        keyLock.lock()
        defer { keyLock.unlock() }
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let (image, hdr) = try Self.downscaledWithGainMaps(source: source, maxPixel: kind.maxPixel)
        try write(image, hdr: hdr, to: target, format: format)
        return target
    }

    /// Preview and thumbnail from a single decode of the original: the thumbnail is made from the preview.
    @discardableResult
    public func ensureAll(id: String, source: URL, editVersion: Int = 0, format: ImageFormat,
                          onDecode: (URL) -> Void = { _ in }) throws -> (thumb: URL, preview: URL) {
        let preview = url(id: id, kind: .preview, editVersion: editVersion, format: format)
        let thumb = url(id: id, kind: .thumb, editVersion: editVersion, format: format)
        let fm = FileManager.default
        if fm.fileExists(atPath: preview.path) && fm.fileExists(atPath: thumb.path) { return (thumb, preview) }
        let keyLock = lockFor(preview.path)
        keyLock.lock()
        defer { keyLock.unlock() }
        if !fm.fileExists(atPath: preview.path) {
            onDecode(source)
            let (image, hdr) = try Self.downscaledWithGainMaps(source: source, maxPixel: DerivativeKind.preview.maxPixel)
            try write(image, hdr: hdr, to: preview, format: format)
        }
        if !fm.fileExists(atPath: thumb.path) {
            let (small, hdr) = try Self.downscaledWithGainMaps(source: preview, maxPixel: DerivativeKind.thumb.maxPixel)
            try write(small, hdr: hdr, to: thumb, format: format)
        }
        return (thumb, preview)
    }

    public func exists(id: String, kind: DerivativeKind, editVersion: Int = 0, format: ImageFormat) -> Bool {
        FileManager.default.fileExists(atPath: url(id: id, kind: kind, editVersion: editVersion, format: format).path)
    }

    public func clear() throws {
        for name in DerivativeKind.allCases.map(\.rawValue) + [Self.gainMapDir] {
            let dir = cacheDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        }
    }

    public func sizeOnDisk() -> Int64 {
        guard let e = FileManager.default.enumerator(at: cacheDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Orientation-corrected SDR image no larger than `maxPixel` on its long edge (never upscaled).
    /// An HDR photo's gain map is not applied: this is the photo as shown on an SDR screen.
    public static func downscaled(source: URL, maxPixel: Int) throws -> CGImage {
        try downscaled(source: try imageSource(source), path: source.path, maxPixel: maxPixel)
    }

    /// `downscaled(source:maxPixel:)` plus the original's HDR gain maps, oriented and resized to match.
    static func downscaledWithGainMaps(source: URL, maxPixel: Int) throws -> (CGImage, HDRMetadata) {
        let src = try imageSource(source)
        let image = try downscaled(source: src, path: source.path, maxPixel: maxPixel)
        let maps = GainMap.all(in: src)
        guard !maps.isEmpty else { return (image, .none) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber).flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let longSide = max(w, h)
        guard longSide > 0 else { return (image, .none) }
        let scale = Double(max(image.width, image.height)) / longSide
        return (image, HDRMetadata(gainMaps: maps.compactMap { $0.transformed(orientation: orientation, scale: scale, context: GainMap.context) },
                                   imageProperties: HDRMetadata.imageProperties(from: props ?? [:])))
    }

    private static func imageSource(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { throw DerivativeError.unreadableSource(url.path) }
        return src
    }

    private static func downscaled(source src: CGImageSource, path: String, maxPixel: Int) throws -> CGImage {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw DerivativeError.unreadableSource(path)
        }
        return img
    }

    /// Stores an edited render as the version's preview, plus a thumbnail made from it.
    func storeEdited(_ preview: CGImage, hdr: HDRMetadata = .none, id: String, version: Int, format: ImageFormat) throws {
        let p = url(id: id, kind: .preview, editVersion: version, format: format)
        let t = url(id: id, kind: .thumb, editVersion: version, format: format)
        let keyLock = lockFor(p.path)
        keyLock.lock()
        defer { keyLock.unlock() }
        try write(preview, hdr: hdr, to: p, format: format)
        let thumb = try Self.downscaled(image: preview, maxPixel: DerivativeKind.thumb.maxPixel)
        try write(thumb, hdr: hdr.scaled(by: Double(thumb.width) / Double(preview.width)), to: t, format: format)
    }

    public func storeEdited(_ preview: CGImage, id: String, version: Int, format: ImageFormat) throws {
        try storeEdited(preview, hdr: .none, id: id, version: version, format: format)
    }

    // MARK: Gain maps for the editor

    static let gainMapDir = "gainmap"

    public func gainMapURL(id: String) -> URL {
        cacheDir.appendingPathComponent(Self.gainMapDir, isDirectory: true)
            .appendingPathComponent(String(id.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(id).gmap")
    }

    /// The photo's normalised gain map (wire format), made once; nil for a photo without one
    /// (remembered as an empty file).
    public func ensureGainMap(id: String, source: URL) throws -> Data? {
        let target = gainMapURL(id: id)
        let keyLock = lockFor(target.path)
        keyLock.lock()
        defer { keyLock.unlock() }
        if let d = try? Data(contentsOf: target) { return d.isEmpty ? nil : d }
        let data = try NormalizedGainMap.make(source: source, maxPixel: NormalizedGainMap.previewMaxPixel)?.encoded() ?? Data()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        return data.isEmpty ? nil : data
    }

    /// `ensureGainMap`, decoded.
    public func gainMap(id: String, source: URL) throws -> NormalizedGainMap? {
        try ensureGainMap(id: id, source: source).map(NormalizedGainMap.decode)
    }

    /// `image` scaled to fit `maxPixel` on its long edge (never upscaled), high-quality resampling.
    public static func downscaled(image: CGImage, maxPixel: Int) throws -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxPixel else { return image }
        let s = Double(maxPixel) / Double(long)
        let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw DerivativeError.encodeFailed("resize") }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw DerivativeError.encodeFailed("resize") }
        return out
    }

    func write(_ image: CGImage, hdr: HDRMetadata = .none, to target: URL, format: ImageFormat) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw DerivativeError.encodeFailed(target.path)
        }
        var props = hdr.imageProperties
        props[kCGImageDestinationLossyCompressionQuality] = format.quality
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        for map in hdr.gainMaps { CGImageDestinationAddAuxiliaryDataInfo(dest, map.type, map.info as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw DerivativeError.encodeFailed(target.path)
        }
        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
    }

    private func lockFor(_ key: String) -> NSLock {
        var h = Hasher()
        h.combine(key)
        return stripes[Int(UInt(bitPattern: h.finalize()) % UInt(stripes.count))]
    }

    /// Deletes every derivative of an asset (all kinds, formats and edit versions).
    public func remove(id: String) {
        let fm = FileManager.default
        for kind in DerivativeKind.allCases {
            let dir = cacheDir.appendingPathComponent(kind.rawValue).appendingPathComponent(String(id.prefix(2)))
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(id + "_") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}
