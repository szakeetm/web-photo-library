import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an export says about a photo: its (possibly adjusted) date, place, description, favourite,
/// people (with face boxes), albums.
public struct ExportInfo: Sendable {
    public var title: String
    public var takenAt: Date
    public var tzOffset: Int?
    public var lat: Double?
    public var lon: Double?
    public var description: String?
    public var favorite: Bool
    public var people: [(name: String, x: Double, y: Double, w: Double, h: Double)]
    public var albums: [String]
    public var width: Int
    public var height: Int
}

/// Date stamps in the formats EXIF and XMP want, in the photo's own time zone.
enum ExportStamp {
    static func zone(_ tz: Int?) -> TimeZone { TimeZone(secondsFromGMT: tz ?? 0) ?? TimeZone(identifier: "UTC")! }

    static func format(_ date: Date, tz: Int?, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone(tz)
        f.dateFormat = pattern
        return f.string(from: date)
    }

    /// "2021:07:04 15:30:00"
    static func exif(_ d: Date, tz: Int?) -> String { format(d, tz: tz, "yyyy:MM:dd HH:mm:ss") }

    /// "+02:00"
    static func offset(_ tz: Int?) -> String {
        let s = tz ?? 0
        return String(format: "%@%02d:%02d", s < 0 ? "-" : "+", abs(s) / 3600, abs(s) % 3600 / 60)
    }

    /// "2021-07-04T15:30:00+02:00" (no offset when unknown)
    static func xmp(_ d: Date, tz: Int?) -> String { format(d, tz: tz, "yyyy-MM-dd'T'HH:mm:ss") + (tz != nil ? offset(tz) : "") }
}

/// Changes the date in a photo file without re-encoding it (ImageIO copies the image data as is).
public enum MetadataRewriter {
    static let supported: Set<String> = [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier,
                                         UTType.png.identifier, UTType.tiff.identifier]

    /// Whether `url`'s format can be rewritten losslessly.
    public static func supports(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { return false }
        return supported.contains(type as String)
    }

    /// Writes a copy of `source` with the date set; false when this file can't be rewritten.
    public static func rewrite(source: URL, to target: URL, takenAt: Date, tzOffset: Int?) -> Bool {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(src),
              supported.contains(type as String),
              let dest = CGImageDestinationCreateWithURL(target as CFURL, type, 1, nil) else { return false }
        // PNG and TIFF are lossless: write the image again with the new date (same pixels); ImageIO's
        // metadata-only copy doesn't update their EXIF.
        if type as String == UTType.png.identifier || type as String == UTType.tiff.identifier {
            var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            dateProperties(takenAt, tzOffset: tzOffset, into: &props)
            CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
            let ok = CGImageDestinationFinalize(dest)
            if !ok { try? FileManager.default.removeItem(at: target) }
            return ok
        }
        let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
        let stamp = ExportStamp.exif(takenAt, tz: tzOffset) as CFString
        let offset = ExportStamp.offset(tzOffset) as CFString
        let exif = kCGImagePropertyExifDictionary
        _ = CGImageMetadataSetValueMatchingImageProperty(meta, exif, kCGImagePropertyExifDateTimeOriginal, stamp)
        _ = CGImageMetadataSetValueMatchingImageProperty(meta, exif, kCGImagePropertyExifDateTimeDigitized, stamp)
        _ = CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime, stamp)
        if tzOffset != nil {
            _ = CGImageMetadataSetValueMatchingImageProperty(meta, exif, kCGImagePropertyExifOffsetTimeOriginal, offset)
            _ = CGImageMetadataSetValueMatchingImageProperty(meta, exif, kCGImagePropertyExifOffsetTimeDigitized, offset)
            _ = CGImageMetadataSetValueMatchingImageProperty(meta, exif, kCGImagePropertyExifOffsetTime, offset)
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        let ok = CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error)
        if !ok { try? FileManager.default.removeItem(at: target) }
        return ok
    }

    /// EXIF/TIFF properties carrying `date`, for files rendered from scratch (edited photos).
    static func dateProperties(_ date: Date, tzOffset: Int?, into props: inout [CFString: Any]) {
        let stamp = ExportStamp.exif(date, tz: tzOffset)
        var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal] = stamp
        exif[kCGImagePropertyExifDateTimeDigitized] = stamp
        if tzOffset != nil {
            exif[kCGImagePropertyExifOffsetTimeOriginal] = ExportStamp.offset(tzOffset)
            exif[kCGImagePropertyExifOffsetTimeDigitized] = ExportStamp.offset(tzOffset)
            exif[kCGImagePropertyExifOffsetTime] = ExportStamp.offset(tzOffset)
        }
        props[kCGImagePropertyExifDictionary] = exif
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFDateTime] = stamp
        props[kCGImagePropertyTIFFDictionary] = tiff
    }
}

/// Sidecar files next to exported photos: Google Photos Takeout JSON or XMP.
public enum SidecarWriter {
    /// Google Photos Takeout's `<name>.supplemental-metadata.json` (the app reads these back too).
    public static func google(_ i: ExportInfo) -> Data {
        let ts = String(Int(i.takenAt.timeIntervalSince1970))
        let formatted = ExportStamp.format(i.takenAt, tz: 0, "MMM d, yyyy, h:mm:ss a 'UTC'")
        var o: [String: Any] = [
            "title": i.title,
            "description": i.description ?? "",
            "imageViews": "0",
            "creationTime": ["timestamp": ts, "formatted": formatted],
            "photoTakenTime": ["timestamp": ts, "formatted": formatted],
        ]
        let geo: [String: Any] = ["latitude": i.lat ?? 0, "longitude": i.lon ?? 0, "altitude": 0.0,
                                  "latitudeSpan": 0.0, "longitudeSpan": 0.0]
        o["geoData"] = geo
        o["geoDataExif"] = geo
        if !i.people.isEmpty { o["people"] = i.people.map { ["name": $0.name] } }
        if i.favorite { o["favorited"] = true }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// An XMP sidecar (`<base>.xmp`): date with time zone, GPS, description, rating 5 for favourites,
    /// keywords (albums and people) and named face regions (MWG), as Lightroom, Capture One,
    /// digiKam and Photos read them.
    public static func xmp(_ i: ExportInfo) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func gps(_ v: Double, _ pos: String, _ neg: String) -> String {
            let a = abs(v)
            return String(format: "%d,%.6f%@", Int(a), (a - Double(Int(a))) * 60, v < 0 ? neg : pos)
        }
        let date = ExportStamp.xmp(i.takenAt, tz: i.tzOffset)
        var attrs = """
             exif:DateTimeOriginal="\(date)"
             xmp:CreateDate="\(date)"
             photoshop:DateCreated="\(date)"
            """
        if let lat = i.lat, let lon = i.lon {
            attrs += "\n exif:GPSLatitude=\"\(gps(lat, "N", "S"))\"\n exif:GPSLongitude=\"\(gps(lon, "E", "W"))\""
        }
        if i.favorite { attrs += "\n xmp:Rating=\"5\"" }
        var body = ""
        if let d = i.description, !d.isEmpty {
            body += "\n   <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(esc(d))</rdf:li></rdf:Alt></dc:description>"
        }
        body += "\n   <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(esc(i.title))</rdf:li></rdf:Alt></dc:title>"
        let keywords = Array(Set(i.albums + i.people.map(\.name))).sorted()
        if !keywords.isEmpty {
            body += "\n   <dc:subject><rdf:Bag>" + keywords.map { "<rdf:li>\(esc($0))</rdf:li>" }.joined() + "</rdf:Bag></dc:subject>"
        }
        if !i.people.isEmpty {
            let regions = i.people.map { p in
                String(format: "<rdf:li><rdf:Description mwg-rs:Name=\"%@\" mwg-rs:Type=\"Face\"><mwg-rs:Area stArea:x=\"%.5f\" stArea:y=\"%.5f\" stArea:w=\"%.5f\" stArea:h=\"%.5f\" stArea:unit=\"normalized\"/></rdf:Description></rdf:li>",
                       esc(p.name), p.x + p.w / 2, p.y + p.h / 2, p.w, p.h)
            }.joined()
            body += """

               <mwg-rs:Regions rdf:parseType="Resource">
                <mwg-rs:AppliedToDimensions stDim:w="\(i.width)" stDim:h="\(i.height)" stDim:unit="pixel"/>
                <mwg-rs:RegionList><rdf:Bag>\(regions)</rdf:Bag></mwg-rs:RegionList>
               </mwg-rs:Regions>
            """
        }
        let xml = """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:exif="http://ns.adobe.com/exif/1.0/"
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
                xmlns:dc="http://purl.org/dc/elements/1.1/"
                xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/"
                xmlns:stDim="http://ns.adobe.com/xap/1.0/sType/Dimensions#"
                xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#"
            \(attrs)>\(body)
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>

            """
        return Data(xml.utf8)
    }
}
