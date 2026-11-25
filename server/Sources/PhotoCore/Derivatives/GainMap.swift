import Foundation
import CoreImage
import ImageIO

/// HDR gain maps (Apple's and ISO 21496-1) carried from an original into its thumbnails and previews.
///
/// A gain-map photo is an ordinary SDR image plus a low-resolution map of how much brighter each area may
/// be shown on an HDR display. Derivatives keep the original's SDR pixels untouched (the editor and SDR
/// screens see exactly what they always did) and get the original's gain maps, resized and oriented to
/// match, so Safari shows them in HDR just like the original.
struct GainMap {
    let type: CFString
    let info: [CFString: Any]

    static var types: [CFString] { [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] }
    /// 'L008': one 8-bit channel, the layout iPhones (and ImageIO's encoder) use.
    static let oneComponent8: UInt32 = 0x4C30_3038

    /// The gain maps of image 0 of `source` (skipping layouts we don't resize, e.g. three-channel maps).
    static func all(in source: CGImageSource) -> [GainMap] {
        types.compactMap { type in
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [CFString: Any],
                  let desc = info[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any],
                  (desc["PixelFormat"] as? NSNumber)?.uint32Value == oneComponent8,
                  info[kCGImageAuxiliaryDataInfoData] is Data else { return nil }
            return GainMap(type: type, info: info)
        }
    }

    private var description: [String: Any] { info[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any] ?? [:] }
    var width: Int { (description["Width"] as? NSNumber)?.intValue ?? 0 }
    var height: Int { (description["Height"] as? NSNumber)?.intValue ?? 0 }

    /// This map for a derivative of the image: `orientation` applied (as the derivative's pixels have it),
    /// then scaled so the map keeps the same resolution relative to the image as in the original
    /// (`scale` = derivative size / oriented original size).
    func transformed(orientation: CGImagePropertyOrientation, scale: Double, context: CIContext) -> GainMap? {
        guard let data = info[kCGImageAuxiliaryDataInfoData] as? Data, width > 0, height > 0,
              let bytesPerRow = (description["BytesPerRow"] as? NSNumber)?.intValue, data.count >= bytesPerRow * height else { return nil }
        var image = CIImage(bitmapData: data, bytesPerRow: bytesPerRow, size: CGSize(width: width, height: height),
                            format: .L8, colorSpace: nil)
            .oriented(orientation)
        let ow = image.extent.width, oh = image.extent.height
        let w = max(1, Int((ow * scale).rounded())), h = max(1, Int((oh * scale).rounded()))
        if w != Int(ow) || h != Int(oh) {
            let f = CIFilter(name: "CILanczosScaleTransform")!
            f.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
            f.setValue(Double(h) / oh, forKey: kCIInputScaleKey)
            f.setValue((Double(w) / ow) / (Double(h) / oh), forKey: kCIInputAspectRatioKey)
            image = f.outputImage!
        }
        let rowBytes = (w + 15) & ~15
        var out = Data(count: rowBytes * h)
        out.withUnsafeMutableBytes { buf in
            context.render(image, toBitmap: buf.baseAddress!, rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: nil)
        }
        var info = info
        info[kCGImageAuxiliaryDataInfoData] = out
        info[kCGImageAuxiliaryDataInfoDataDescription] = [
            "Width": w, "Height": h, "BytesPerRow": rowBytes, "PixelFormat": Self.oneComponent8,
        ] as [String: Any]
        return GainMap(type: type, info: info)
    }

    /// Shared, colour-management-free context (gain maps are data, not colours).
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
}

/// What a derivative needs to be shown in HDR: the gain maps, plus image metadata that Apple's original
/// (pre-ISO) gain-map format reads its headroom from.
struct HDRMetadata {
    var gainMaps: [GainMap]
    var imageProperties: [CFString: Any]

    static var none: HDRMetadata { HDRMetadata(gainMaps: [], imageProperties: [:]) }

    /// Apple's gain map is scaled by the photo's headroom, kept in Apple maker-note tags 33 and 48; without
    /// them Safari and ImageIO ignore the map. Only those two tags are copied.
    static func imageProperties(from source: [CFString: Any]) -> [CFString: Any] {
        guard let maker = source[kCGImagePropertyMakerAppleDictionary] as? [AnyHashable: Any] else { return [:] }
        let keep = maker.filter { "\($0.key)" == "33" || "\($0.key)" == "48" }
        return keep.isEmpty ? [:] : [kCGImagePropertyMakerAppleDictionary: keep]
    }
}
