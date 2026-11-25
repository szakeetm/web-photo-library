import Foundation

public struct ResolvedMetadata: Sendable, Equatable {
    public var takenAt: Date
    public var tzOffset: Int?
    public var dateSource: String      // sidecar | exif | file
    public var lat: Double?
    public var lon: Double?
    public var locationSource: String? // sidecar | exif
    public var description: String?
    public var favorited: Bool?
}

/// Applies the precedence sidecar → EXIF → file date, per field.
public enum MetadataResolver {
    public static func resolve(probe: ProbeResult, sidecar: SidecarData?, fileMTime: Date, serverTZ: TimeZone) -> ResolvedMetadata {
        let takenAt: Date
        let source: String
        var tz: Int?

        if let s = sidecar?.takenAt {
            takenAt = s
            source = "sidecar"
            if let o = probe.exifOffset {
                tz = o
            } else if let local = probe.exifLocalDate, let derived = derivedOffset(local: local, instant: s) {
                tz = derived
            } else {
                tz = serverTZ.secondsFromGMT(for: s)
            }
        } else if let abs = probe.exifDate {
            takenAt = abs
            source = "exif"
            tz = probe.exifOffset
        } else if let local = probe.exifLocalDate {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = serverTZ
            takenAt = cal.date(from: local) ?? fileMTime
            source = "exif"
            tz = serverTZ.secondsFromGMT(for: takenAt)
        } else {
            takenAt = fileMTime
            source = "file"
            tz = serverTZ.secondsFromGMT(for: fileMTime)
        }

        return finish(takenAt: takenAt, tz: tz, source: source, embeddedLat: probe.lat, embeddedLon: probe.lon, sidecar: sidecar)
    }

    /// Same precedence for a video: sidecar → embedded QuickTime metadata (reported as "exif") → file date.
    public static func resolve(video: VideoProbeResult, sidecar: SidecarData?, fileMTime: Date, serverTZ: TimeZone) -> ResolvedMetadata {
        let takenAt: Date
        let source: String
        let tz: Int?
        if let s = sidecar?.takenAt {
            (takenAt, source) = (s, "sidecar")
            tz = video.tzOffset ?? serverTZ.secondsFromGMT(for: s)
        } else if let d = video.takenAt {
            (takenAt, source) = (d, "exif")
            tz = video.tzOffset
        } else {
            (takenAt, source) = (fileMTime, "file")
            tz = serverTZ.secondsFromGMT(for: fileMTime)
        }
        return finish(takenAt: takenAt, tz: tz, source: source, embeddedLat: video.lat, embeddedLon: video.lon, sidecar: sidecar)
    }

    private static func finish(takenAt: Date, tz: Int?, source: String, embeddedLat: Double?, embeddedLon: Double?,
                               sidecar: SidecarData?) -> ResolvedMetadata {
        var lat: Double?, lon: Double?, locSource: String?
        if let la = sidecar?.lat, let lo = sidecar?.lon {
            (lat, lon, locSource) = (la, lo, "sidecar")
        } else if let la = embeddedLat, let lo = embeddedLon {
            (lat, lon, locSource) = (la, lo, "exif")
        }
        return ResolvedMetadata(takenAt: takenAt, tzOffset: tz, dateSource: source, lat: lat, lon: lon,
                                locationSource: locSource, description: sidecar?.description, favorited: sidecar?.favorited)
    }

    /// Offset implied by a camera wall-clock time and a known UTC instant, rounded to 15 minutes.
    static func derivedOffset(local: DateComponents, instant: Date) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let asUTC = cal.date(from: local) else { return nil }
        let raw = asUTC.timeIntervalSince(instant)
        let rounded = Int((raw / 900).rounded()) * 900
        return abs(rounded) <= 14 * 3600 ? rounded : nil
    }
}
