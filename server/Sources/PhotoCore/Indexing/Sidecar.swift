import Foundation

public struct SidecarData: Sendable, Equatable {
    public var takenAt: Date?
    public var lat: Double?
    public var lon: Double?
    public var description: String?
    public var favorited: Bool?
}

/// Finds the Google Takeout JSON sidecar for an image among the entries of its directory.
public enum SidecarLocator {
    static let supplemental = "supplemental-metadata"
    static let editedSuffixes = ["-edited", "-bearbeitet", "-modifié", "-editado", "-modificato", "-modifie"]
    static let minTruncatedStem = 30

    public static func sidecar(for imageName: String, in dirEntries: Set<String>) -> String? {
        // Compare in NFC; map back to the on-disk spelling.
        var byNFC: [String: String] = [:]
        for e in dirEntries where e.lowercased().hasSuffix(".json") { byNFC[nfc(e)] = e }
        let name = nfc(imageName)
        guard let hit = locate(name, jsons: byNFC) else { return nil }
        return byNFC[hit]
    }

    static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    private static func locate(_ name: String, jsons: [String: String]) -> String? {
        if let direct = direct(name, counter: nil, jsons: jsons) { return direct }

        // Duplicate counter: "B(k).ext" ↔ "B.ext(k).json"
        if let (base, k, ext) = splitCounter(name),
           let hit = direct(base + ext, counter: k, jsons: jsons) { return hit }

        // Edited copies use the original's sidecar.
        let (stem, ext) = splitExt(name)
        for suffix in editedSuffixes where stem.lowercased().hasSuffix(suffix) {
            let original = String(stem.dropLast(suffix.count)) + ext
            if let hit = locate(original, jsons: jsons) { return hit }
        }

        // Truncated long names: a unique json whose stem is a long-enough prefix of the name.
        let matches = jsons.keys.filter { key in
            let s = jsonStem(key)
            return s.count >= minTruncatedStem && s != name && name.hasPrefix(s)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func direct(_ name: String, counter: String?, jsons: [String: String]) -> String? {
        let c = counter.map { "(\($0))" } ?? ""
        for candidate in ["\(name)\(c).json", "\(name).\(supplemental)\(c).json"] where jsons[candidate] != nil {
            return candidate
        }
        // Truncated "supplemental-metadata" suffix, e.g. "IMG.jpg.supplemental-metad.json"
        let prefix = name + "."
        let suffix = c + ".json"
        for key in jsons.keys.sorted() where key.hasPrefix(prefix) && key.hasSuffix(suffix) {
            let middle = key.dropFirst(prefix.count).dropLast(suffix.count)
            if !middle.isEmpty && supplemental.hasPrefix(middle) { return key }
        }
        return nil
    }

    private static func splitExt(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// "B(12).ext" → ("B", "12", ".ext")
    private static func splitCounter(_ name: String) -> (String, String, String)? {
        let (stem, ext) = splitExt(name)
        guard stem.hasSuffix(")"), let open = stem.lastIndex(of: "(") else { return nil }
        let digits = stem[stem.index(after: open)..<stem.index(before: stem.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return (String(stem[..<open]), String(digits), ext)
    }

    /// Strips ".json", a trailing "(k)" counter and a (possibly truncated) supplemental-metadata part.
    private static func jsonStem(_ key: String) -> String {
        var s = String(key.dropLast(5))
        if let (base, _, ext) = splitCounter(s + ".x"), ext == ".x" { s = base }
        if let dot = s.lastIndex(of: ".") {
            let tail = s[s.index(after: dot)...]
            if !tail.isEmpty && supplemental.hasPrefix(tail) { s = String(s[..<dot]) }
        }
        return s
    }
}

public enum SidecarParser {
    private struct Raw: Decodable {
        struct Time: Decodable { let timestamp: String? }
        struct Geo: Decodable { let latitude: Double?; let longitude: Double? }
        let photoTakenTime: Time?
        let geoData: Geo?
        let geoDataExif: Geo?
        let description: String?
        let favorited: Bool?
    }

    public static func parse(_ data: Data) -> SidecarData? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        var out = SidecarData()
        if let ts = raw.photoTakenTime?.timestamp, let secs = Double(ts), secs > 0 {
            out.takenAt = Date(timeIntervalSince1970: secs)
        }
        for geo in [raw.geoData, raw.geoDataExif] {
            if let la = geo?.latitude, let lo = geo?.longitude, !(la == 0 && lo == 0) {
                out.lat = la; out.lon = lo
                break
            }
        }
        if let d = raw.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { out.description = d }
        out.favorited = raw.favorited
        return out
    }
}
