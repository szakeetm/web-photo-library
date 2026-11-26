import Foundation
import GRDB

public struct SettingKey<T: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: T
    public init(_ name: String, default defaultValue: T) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

extension SettingKey where T == String? {
    public static let libraryPath = SettingKey("libraryPath", default: nil)
    public static let ownerLogin = SettingKey("ownerLogin", default: nil)
    /// Writable folder for uploads (phone-uploads/, desktop-uploads/); separate from the read-only library.
    public static let uploadsPath = SettingKey("uploadsPath", default: nil)
}

extension SettingKey where T == Bool {
    /// Face recognition (detection + grouping into people) runs after scans.
    public static let facesEnabled = SettingKey("facesEnabled", default: true)
}

extension SettingKey where T == String? {
    /// MapLibre style for the Places map (default: OpenFreeMap "liberty").
    public static let mapStyleURL = SettingKey("mapStyleURL", default: nil)
}

extension SettingKey where T == Int? {
    /// Parallel workers for indexing and image generation (nil = default, up to 8).
    public static let workers = SettingKey("workers", default: nil)
    /// Converted videos (previews, H.264 copies, motion clips) not played for this many days are deleted (nil = kept).
    public static let videoCacheDays = SettingKey("videoCacheDays", default: nil)
}

/// Untyped JSON value, used to expose all settings over the API.
public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public final class SettingsStore: Sendable {
    private let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    public func get<T>(_ key: SettingKey<T>) throws -> T {
        let raw = try db.writer.read { try String.fetchOne($0, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key.name]) }
        guard let raw, let data = raw.data(using: .utf8) else { return key.defaultValue }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func set<T>(_ key: SettingKey<T>, _ value: T) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.writer.write {
            try $0.execute(sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key.name, json])
        }
    }

    public func all() throws -> [String: JSONValue] {
        let rows = try db.writer.read { try Row.fetchAll($0, sql: "SELECT key, value FROM setting") }
        var out: [String: JSONValue] = [:]
        for row in rows {
            let key: String = row["key"]
            let value: String = row["value"]
            out[key] = (try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))) ?? .null
        }
        return out
    }
}
