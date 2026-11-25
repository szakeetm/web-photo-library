import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

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

    /// Writes a short solid-colour video with optional QuickTime content id, creation date and ISO 6709 location.
    static func writeVideo(to url: URL, width: Int, height: Int, codec: AVVideoCodecType = .h264,
                           seconds: Double = 1, rotate90: Bool = false, contentId: String? = nil,
                           creationDate: String? = nil, location: String? = nil) async throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height])
        if rotate90 { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMutableMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            m.value = value as NSString
            return m
        }
        var meta: [AVMetadataItem] = []
        if let contentId { meta.append(item(.quickTimeMetadataContentIdentifier, contentId)) }
        if let creationDate { meta.append(item(.quickTimeMetadataCreationDate, creationDate)) }
        if let location { meta.append(item(.quickTimeMetadataLocationISO6709, location)) }
        writer.metadata = meta
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let fps = 10
        for i in 0..<Int(seconds * Double(fps)) {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            memset(CVPixelBufferGetBaseAddress(buf), 0x80, CVPixelBufferGetBytesPerRow(buf) * height)
            CVPixelBufferUnlockBaseAddress(buf, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
