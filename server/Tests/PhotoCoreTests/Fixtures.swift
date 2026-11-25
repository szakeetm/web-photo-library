import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum Fixtures {
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a solid-colour JPEG with optional EXIF date/offset, GPS and orientation.
    static func writeJPEG(to url: URL, width: Int = 800, height: Int = 600,
                          dateTimeOriginal: String? = nil, offset: String? = nil,
                          gps: (lat: Double, lon: Double)? = nil, orientation: Int? = nil,
                          color: (CGFloat, CGFloat, CGFloat) = (0.2, 0.4, 0.8), type: UTType = .jpeg) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // a white marker in the top-left corner so orientation is observable
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: height - height / 4, width: width / 4, height: height / 4))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        var exif: [CFString: Any] = [:]
        if let d = dateTimeOriginal { exif[kCGImagePropertyExifDateTimeOriginal] = d }
        if let o = offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = o }
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
        if let gps {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(gps.lat), kCGImagePropertyGPSLatitudeRef: gps.lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(gps.lon), kCGImagePropertyGPSLongitudeRef: gps.lon >= 0 ? "E" : "W",
            ]
        }
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
    }
}
