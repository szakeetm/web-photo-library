import Foundation
import ImageIO

public struct ProbeResult: Sendable, Equatable {
    public var width: Int            // oriented (display) width
    public var height: Int           // oriented (display) height
    public var mime: String          // UTType identifier, e.g. public.jpeg
    public var exifDate: Date?       // absolute instant, only when an EXIF offset is known
    public var exifLocalDate: DateComponents?  // wall-clock time as recorded by the camera
    public var exifOffset: Int?      // seconds east of UTC
    public var lat: Double?
    public var lon: Double?
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Double?
    public var aperture: Double?
    public var shutter: Double?
    public var focal: Double?
    public var orientation: Int
    public var contentId: String? = nil   // Apple Live Photo id (MakerNote key 17)
}

public enum ImageProbe {
    public static func probe(url: URL) -> ProbeResult? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let type = CGImageSourceGetType(src),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any],
              let pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, pw > 0, ph > 0
        else { return nil }

        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swap = (5...8).contains(orientation)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        let dateString = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        let local = dateString.flatMap(parseExifDate)
        let offset = ((exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifOffsetTime] as? String)).flatMap(parseOffset)
        var absolute: Date?
        if let local, let offset, let tz = TimeZone(secondsFromGMT: offset) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            absolute = cal.date(from: local)
        }

        var lat: Double?, lon: Double?
        if let la = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let lo = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
            lat = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -la : la
            lon = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lo : lo
            if lat == 0 && lon == 0 { lat = nil; lon = nil }
        }

        func num(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let a = v as? [NSNumber], let f = a.first { return f.doubleValue }
            return nil
        }

        return ProbeResult(
            width: swap ? ph : pw, height: swap ? pw : ph, mime: type as String,
            exifDate: absolute, exifLocalDate: local, exifOffset: offset, lat: lat, lon: lon,
            make: tiff[kCGImagePropertyTIFFMake] as? String, model: tiff[kCGImagePropertyTIFFModel] as? String,
            lens: exif[kCGImagePropertyExifLensModel] as? String,
            iso: num(exif[kCGImagePropertyExifISOSpeedRatings]), aperture: num(exif[kCGImagePropertyExifFNumber]),
            shutter: num(exif[kCGImagePropertyExifExposureTime]), focal: num(exif[kCGImagePropertyExifFocalLength]),
            orientation: orientation, contentId: appleContentId(props))
    }

    /// Live Photo content id: `kCGImagePropertyMakerAppleDictionary["17"]`.
    static func appleContentId(_ props: [CFString: Any]) -> String? {
        let maker = props[kCGImagePropertyMakerAppleDictionary] as? [AnyHashable: Any]
        return maker?["17"] as? String
    }

    /// "yyyy:MM:dd HH:mm:ss" → wall-clock components.
    static func parseExifDate(_ s: String) -> DateComponents? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(whereSeparator: { ": -T".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 6, parts[0] > 1800, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
    }

    /// "+02:00" / "-05:30" → seconds east of UTC.
    static func parseOffset(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let hm = t.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return nil }
        let secs = hm[0] * 3600 + hm[1] * 60
        return sign == "-" ? -secs : secs
    }
}
