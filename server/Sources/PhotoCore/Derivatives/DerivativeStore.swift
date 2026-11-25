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

    public init(cacheDir: URL) { self.cacheDir = cacheDir }

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
        let image = try Self.downscaled(source: source, maxPixel: kind.maxPixel)
        try write(image, to: target, format: format)
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
            let image = try Self.downscaled(source: source, maxPixel: DerivativeKind.preview.maxPixel)
            try write(image, to: preview, format: format)
        }
        if !fm.fileExists(atPath: thumb.path) {
            let small = try Self.downscaled(source: preview, maxPixel: DerivativeKind.thumb.maxPixel)
            try write(small, to: thumb, format: format)
        }
        return (thumb, preview)
    }

    public func exists(id: String, kind: DerivativeKind, editVersion: Int = 0, format: ImageFormat) -> Bool {
        FileManager.default.fileExists(atPath: url(id: id, kind: kind, editVersion: editVersion, format: format).path)
    }

    public func clear() throws {
        for kind in DerivativeKind.allCases {
            let dir = cacheDir.appendingPathComponent(kind.rawValue)
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

    /// Orientation-corrected image no larger than `maxPixel` on its long edge (never upscaled).
    public static func downscaled(source: URL, maxPixel: Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { throw DerivativeError.unreadableSource(source.path) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw DerivativeError.unreadableSource(source.path)
        }
        return img
    }

    private func write(_ image: CGImage, to target: URL, format: ImageFormat) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw DerivativeError.encodeFailed(target.path)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: format.quality] as CFDictionary)
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
