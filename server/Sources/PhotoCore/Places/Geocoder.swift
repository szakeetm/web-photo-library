import Foundation

/// A GeoNames place (city / town / village with at least 1000 people).
public struct GeoPlace: Codable, Sendable, Equatable {
    public var id: Int64
    public var name: String
    public var region: String?
    public var country: String
    public var countryCode: String
    public var lat: Double
    public var lon: Double
}

/// Offline reverse geocoder over the bundled GeoNames table (geonames.deflate, built by
/// tools/geonames). Nearest place within `maxKm`, searched in a 1°×1° grid.
public final class Geocoder: Sendable {
    /// Bump when the table or the matching rule changes: assets are re-geocoded.
    public static let version = 2
    public static let maxKm = 80.0

    struct Entry: Sendable { let id: Int64; let name: String; let lat: Double; let lon: Double; let cc: String; let admin1: String; let bonus: Double }
    let entries: [Entry]
    let grid: [Int: [Int32]]
    let countries: [String: String]
    let regions: [String: String]

    nonisolated(unsafe) private static var cached: Geocoder?
    private static let lock = NSLock()

    public static func shared() throws -> Geocoder {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        guard let url = Bundle.module.url(forResource: "geonames", withExtension: "deflate") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let g = try Geocoder(deflated: Data(contentsOf: url))
        cached = g
        return g
    }

    init(deflated: Data) throws {
        let raw = try (deflated as NSData).decompressed(using: .zlib) as Data
        var entries: [Entry] = []
        entries.reserveCapacity(170_000)
        var countries: [String: String] = [:]
        var regions: [String: String] = [:]
        let text = String(decoding: raw, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            switch f.first {
            case "C" where f.count >= 3: countries[String(f[1])] = String(f[2])
            case "A" where f.count >= 3: regions[String(f[1])] = String(f[2])
            case "P" where f.count >= 7:
                guard let id = Int64(f[1]), let lat = Double(f[3]), let lon = Double(f[4]) else { continue }
                let pop = f.count > 7 ? Double(f[7]) ?? 0 : 0
                entries.append(Entry(id: id, name: String(f[2]), lat: lat, lon: lon, cc: String(f[5]), admin1: String(f[6]),
                                     bonus: Self.sizeBonusKm * log10(pop / 1000 + 1)))
            default: continue
            }
        }
        var grid: [Int: [Int32]] = [:]
        for (i, e) in entries.enumerated() { grid[Self.cell(e.lat, e.lon), default: []].append(Int32(i)) }
        self.entries = entries
        self.grid = grid
        self.countries = countries
        self.regions = regions
    }

    static func cell(_ lat: Double, _ lon: Double) -> Int {
        let la = Int(floor(lat)).clamped(-90, 89) + 90
        let lo = ((Int(floor(lon)) + 180) % 360 + 360) % 360
        return la * 360 + lo
    }

    static func km(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = 6371.0
        let dLat = (b.0 - a.0) * .pi / 180, dLon = (b.1 - a.1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.0 * .pi / 180) * cos(b.0 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// A bigger place wins over a slightly closer small one (a city over its own districts): each
    /// place counts as this many km closer per tenfold population (in thousands).
    static let sizeBonusKm = 4.0

    public func place(lat: Double, lon: Double) -> GeoPlace? {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { return nil }
        var best: (Int32, Double, Double)?  // index, score, distance
        // 1° of longitude shrinks towards the poles: widen the search there.
        let lonSpan = min(180, Int(ceil(1 / max(0.05, cos(lat * .pi / 180)))))
        for dLat in -1...1 {
            for dLon in -lonSpan...lonSpan {
                guard let idx = grid[Self.cell(lat + Double(dLat), lon + Double(dLon))] else { continue }
                for i in idx {
                    let e = entries[Int(i)]
                    let d = Self.km((lat, lon), (e.lat, e.lon))
                    guard d <= Self.maxKm else { continue }
                    let score = d - e.bonus
                    if score < (best?.1 ?? .infinity) { best = (i, score, d) }
                }
            }
        }
        guard let (i, _, _) = best else { return nil }
        let e = entries[Int(i)]
        return GeoPlace(id: e.id, name: e.name, region: regions["\(e.cc).\(e.admin1)"], country: countries[e.cc] ?? e.cc,
                        countryCode: e.cc, lat: e.lat, lon: e.lon)
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(hi, Swift.max(lo, self)) }
}
