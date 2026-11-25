import Foundation
import GRDB

/// Place as shipped in the catalog.
public struct CatalogPlace: Codable, Sendable, Equatable {
    public var id: Int64
    public var name: String
    public var region: String?
    public var country: String
    public var cc: String
    public var lat: Double
    public var lon: Double
}

/// Reverse-geocodes photos with a location (offline, bundled GeoNames).
public final class PlaceService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Geocodes every present asset with coordinates that wasn't geocoded with the current table.
    @discardableResult
    public func geocodePending(ids: [String]? = nil) throws -> Int {
        let rows = try db.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, lat, lon, placeId FROM asset
                WHERE missingSince IS NULL AND placeVersion < ? \(ids == nil ? "" : "AND id IN (SELECT value FROM json_each(?))")
                """, arguments: ids == nil ? [Geocoder.version] : [Geocoder.version, String(decoding: try JSONEncoder().encode(ids!), as: UTF8.self)])
        }
        guard !rows.isEmpty else { return 0 }
        let geo = try Geocoder.shared()
        var changed = 0
        try db.writer.write { d in
            for r in rows {
                let id: String = r["id"]
                let lat: Double? = r["lat"], lon: Double? = r["lon"]
                let old: Int64? = r["placeId"]
                let p = (lat != nil && lon != nil) ? geo.place(lat: lat!, lon: lon!) : nil
                if let p {
                    try d.execute(sql: """
                        INSERT INTO place (id, name, region, country, countryCode, lat, lon) VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, region = excluded.region, country = excluded.country
                        """, arguments: [p.id, p.name, p.region, p.country, p.countryCode, p.lat, p.lon])
                }
                try d.execute(sql: "UPDATE asset SET placeId = ?, placeVersion = ? WHERE id = ?", arguments: [p?.id, Geocoder.version, id])
                if old != p?.id {
                    try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
                    changed += 1
                }
            }
            if changed > 0 { try ChangeLog.record(d, entity: "place", id: "*", op: "upsert") }
        }
        return changed
    }

    /// Places that have at least one present photo.
    static func catalogPlaces(_ d: Database) throws -> [CatalogPlace] {
        try Row.fetchAll(d, sql: """
            SELECT p.* FROM place p WHERE EXISTS (SELECT 1 FROM asset a WHERE a.placeId = p.id AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id))
            ORDER BY p.country, p.region, p.name
            """).map {
            CatalogPlace(id: $0["id"], name: $0["name"], region: $0["region"], country: $0["country"], cc: $0["countryCode"],
                         lat: $0["lat"], lon: $0["lon"])
        }
    }
}
