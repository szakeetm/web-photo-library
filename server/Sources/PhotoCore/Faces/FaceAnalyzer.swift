import Foundation
import CoreGraphics
import CoreML
import Vision

/// A face found in an (oriented, unedited) preview image.
public struct DetectedFace: Sendable {
    /// Normalised box, origin top-left.
    public var x: Double, y: Double, w: Double, h: Double
    public var quality: Double
    /// L2-normalised embedding (cosine similarity = dot product).
    public var embedding: [Float]
}

public enum FaceError: Error, CustomStringConvertible {
    case modelMissing(String), model(String)
    public var description: String {
        switch self {
        case .modelMissing(let p): "The face recognition model isn't installed (\(p)). Run tools/face-model/make.sh on the Mac."
        case .model(let m): "Face recognition model error: \(m)"
        }
    }
}

/// Face detection (Apple Vision) + embedding (FaceNet, Core ML on the Neural Engine).
public final class FaceAnalyzer: @unchecked Sendable {
    /// Bump when detection, alignment or the model changes: photos are scanned again.
    public static let version = 1
    public static let inputSize = 160
    /// Faces smaller than this (pixels, short side of the box in the 2048 px preview) are ignored.
    public static let minFacePixels = 40.0
    public static let minQuality = 0.15

    let model: MLModel
    private let lock = NSLock()

    public static func modelURL(dataDir: URL) -> URL {
        dataDir.appendingPathComponent("models/FaceNet.mlpackage", isDirectory: true)
    }

    public static func modelInstalled(dataDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(dataDir: dataDir).path)
    }

    /// Compiles the model on first use (kept next to the package) and loads it for the Neural Engine.
    public init(dataDir: URL) throws {
        let package = Self.modelURL(dataDir: dataDir)
        guard FileManager.default.fileExists(atPath: package.path) else { throw FaceError.modelMissing(package.path) }
        let compiled = package.deletingLastPathComponent().appendingPathComponent("FaceNet.mlmodelc", isDirectory: true)
        let fm = FileManager.default
        let pkgDate = (try? fm.attributesOfItem(atPath: package.path)[.modificationDate] as? Date) ?? .distantPast
        let compiledDate = (try? fm.attributesOfItem(atPath: compiled.path)[.modificationDate] as? Date) ?? .distantPast
        do {
            if !fm.fileExists(atPath: compiled.path) || compiledDate < pkgDate {
                let tmp = try MLModel.compileModel(at: package)
                try? fm.removeItem(at: compiled)
                try fm.moveItem(at: tmp, to: compiled)
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            model = try MLModel(contentsOf: compiled, configuration: config)
        } catch {
            throw FaceError.model(String(describing: error))
        }
    }

    public func analyze(_ image: CGImage) throws -> [DetectedFace] {
        let landmarks = VNDetectFaceLandmarksRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([landmarks])
        let found = landmarks.results ?? []
        guard !found.isEmpty else { return [] }
        quality.inputFaceObservations = found
        try handler.perform([quality])
        let qualities = quality.results ?? found
        let W = Double(image.width), H = Double(image.height)
        var out: [DetectedFace] = []
        for (i, f) in found.enumerated() {
            let q = Double(i < qualities.count ? (qualities[i].faceCaptureQuality ?? 0.5) : 0.5)
            let b = f.boundingBox  // normalised, origin bottom-left
            let wPx = b.width * W, hPx = b.height * H
            guard min(wPx, hPx) >= Self.minFacePixels, q >= Self.minQuality else { continue }
            guard let crop = Self.alignedCrop(image, face: f) else { continue }
            let emb = try embed(crop)
            out.append(DetectedFace(x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height, quality: q, embedding: emb))
        }
        return out
    }

    /// Square crop around the face, rotated so the eyes are level (MTCNN-like margin), 160×160 RGB.
    static func alignedCrop(_ image: CGImage, face: VNFaceObservation) -> CGImage? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let b = face.boundingBox
        // pixel coordinates, origin bottom-left (Core Graphics)
        let box = CGRect(x: b.minX * W, y: b.minY * H, width: b.width * W, height: b.height * H)
        var angle: CGFloat = 0
        if let l = face.landmarks?.leftEye?.pointsInImage(imageSize: CGSize(width: W, height: H)),
           let r = face.landmarks?.rightEye?.pointsInImage(imageSize: CGSize(width: W, height: H)), !l.isEmpty, !r.isEmpty {
            let lc = l.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let rc = r.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let le = CGPoint(x: lc.x / CGFloat(l.count), y: lc.y / CGFloat(l.count))
            let re = CGPoint(x: rc.x / CGFloat(r.count), y: rc.y / CGFloat(r.count))
            // Vision's "left eye" is the subject's left (image right): measure from image-left to image-right eye
            let (a, c) = le.x < re.x ? (le, re) : (re, le)
            angle = atan2(c.y - a.y, c.x - a.x)
        } else if let roll = face.roll?.doubleValue {
            angle = -CGFloat(roll)
        }
        let side = max(box.width, box.height) * 1.25
        let n = CGFloat(inputSize)
        guard let ctx = CGContext(data: nil, width: inputSize, height: inputSize, bitsPerComponent: 8, bytesPerRow: inputSize * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        // map: image point → crop: translate face centre to origin, undo the tilt, scale, recentre
        ctx.translateBy(x: n / 2, y: n / 2)
        ctx.scaleBy(x: n / side, y: n / side)
        ctx.rotate(by: -angle)
        ctx.translateBy(x: -box.midX, y: -box.midY)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        return ctx.makeImage()
    }

    func embed(_ crop: CGImage) throws -> [Float] {
        let n = Self.inputSize
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &rgba, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FaceError.model("context")
        }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: n, height: n))
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32)
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * n * n)
        for i in 0..<(n * n) {
            for c in 0..<3 { ptr[c * n * n + i] = (Float(rgba[i * 4 + c]) - 127.5) / 128 }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(multiArray: input)])
        lock.lock(); defer { lock.unlock() }
        let result = try model.prediction(from: provider)
        guard let arr = result.featureValue(for: "embedding")?.multiArrayValue else { throw FaceError.model("no embedding") }
        var v = (0..<arr.count).map { Float(truncating: arr[$0]) }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }
}
