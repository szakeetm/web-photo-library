import Foundation
import GRDB

/// A date change for several photos at once. The instant moves by `shift` seconds (or becomes `setTo`
/// for all of them); with `tzOffset` the photos get that time zone, either keeping the wall-clock time
/// they showed (`keepWallClock`) or keeping the instant (the clock reading changes instead).
public struct DateChange: Codable, Sendable, Equatable {
    public var shift: Double
    public var setTo: Date?
    public var tzOffset: Int?
    public var keepWallClock: Bool

    public init(shift: Double = 0, setTo: Date? = nil, tzOffset: Int? = nil, keepWallClock: Bool = false) {
        self.shift = shift
        self.setTo = setTo
        self.tzOffset = tzOffset
        self.keepWallClock = keepWallClock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shift = try c.decodeIfPresent(Double.self, forKey: .shift) ?? 0
        setTo = try c.decodeIfPresent(String.self, forKey: .setTo).flatMap { ISO8601DateFormatter().date(from: $0) }
        tzOffset = try c.decodeIfPresent(Int.self, forKey: .tzOffset)
        keepWallClock = try c.decodeIfPresent(Bool.self, forKey: .keepWallClock) ?? false
    }
}

public enum MetadataError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let s): s }
    }
}

/// Dates the user set. They live only in the database (`meta_edit`), never in the library's files; the
/// scanner applies them on top of the date read from the file, and exports write them into the copy.
public final class MetadataService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Applies a change to every photo in `ids` (relative to each one's current, effective date).
    public func change(ids: [String], _ c: DateChange) throws {
        guard c.shift.isFinite, abs(c.shift) < 200 * 365 * 86400 else { throw MetadataError.invalid("Invalid time shift.") }
        if let tz = c.tzOffset, abs(tz) > 14 * 3600 { throw MetadataError.invalid("Invalid time zone.") }
        try db.writer.write { d in
            for id in Set(ids) {
                guard var a = try Asset.fetchOne(d, key: id) else { continue }
                var t = c.setTo ?? a.takenAt.addingTimeInterval(c.shift)
                var tz = a.tzOffset
                if let newTz = c.tzOffset {
                    if c.keepWallClock && c.setTo == nil { t = t.addingTimeInterval(TimeInterval((a.tzOffset ?? newTz) - newTz)) }
                    tz = newTz
                }
                // Back to exactly the file's date: no override needed.
                if t == a.fileTakenAt && tz == a.fileTzOffset {
                    try d.execute(sql: "DELETE FROM meta_edit WHERE assetId = ?", arguments: [id])
                } else {
                    try d.execute(sql: "INSERT OR REPLACE INTO meta_edit (assetId, takenAt, tzOffset, createdAt) VALUES (?, ?, ?, ?)",
                                  arguments: [id, t, tz, Date()])
                }
                try Self.applyOverride(d, to: &a)
                try a.update(d)
                try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
            }
        }
    }

    /// Goes back to the dates read from the files.
    public func revert(ids: [String]) throws {
        try db.writer.write { d in
            for id in Set(ids) {
                guard var a = try Asset.fetchOne(d, key: id) else { continue }
                try d.execute(sql: "DELETE FROM meta_edit WHERE assetId = ?", arguments: [id])
                try Self.applyOverride(d, to: &a)
                try a.update(d)
                try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
            }
        }
    }

    /// Sets `a.takenAt/tzOffset/dateSource` to the user's date when there is one, else to the file's.
    static func applyOverride(_ d: Database, to a: inout Asset) throws {
        if let row = try Row.fetchOne(d, sql: "SELECT takenAt, tzOffset FROM meta_edit WHERE assetId = ?", arguments: [a.id]) {
            a.takenAt = row["takenAt"]
            a.tzOffset = row["tzOffset"]
            a.dateSource = "user"
        } else if let t = a.fileTakenAt {
            a.takenAt = t
            a.tzOffset = a.fileTzOffset
            a.dateSource = a.fileDateSource ?? a.dateSource
        }
    }

    /// The photo's content changed (same file): its date change follows it.
    static func relink(_ d: Database, from oldId: String, to newId: String) throws {
        guard try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM meta_edit WHERE assetId = ?", arguments: [newId]) == 0 else { return }
        try d.execute(sql: """
            INSERT OR IGNORE INTO meta_edit (assetId, takenAt, tzOffset, createdAt)
            SELECT ?, takenAt, tzOffset, createdAt FROM meta_edit WHERE assetId = ?
            """, arguments: [newId, oldId])
        guard var a = try Asset.fetchOne(d, key: newId) else { return }
        try applyOverride(d, to: &a)
        try a.update(d)
    }

    /// The user's date, if set.
    public func override(id: String) throws -> (takenAt: Date, tzOffset: Int?)? {
        try db.writer.read { d in
            try Row.fetchOne(d, sql: "SELECT takenAt, tzOffset FROM meta_edit WHERE assetId = ?", arguments: [id])
                .map { ($0["takenAt"], $0["tzOffset"]) }
        }
    }
}
