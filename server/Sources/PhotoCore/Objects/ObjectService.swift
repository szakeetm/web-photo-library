import CoreGraphics
import Foundation
import GRDB
import Vision

/// A kind of thing recognised in photos ("dog", "beach"…), with how many photos and videos show it.
public struct ObjectLabel: Codable, Sendable, Equatable {
    public var id: Int64
    /// Vision's identifier ("sea_lion"); clients format it for display.
    public var name: String
    public var count: Int
    public var coverId: String?
}

public struct ObjectTag: Codable, Sendable, Equatable {
    public var id: Int64
    public var name: String
}

/// Object recognition with Vision's built-in image classifier (no model download; runs on the
/// Neural Engine/GPU). Only labels Vision is confident about are kept (≥ 90 % precision), so
/// browsing by them shows few false matches.
public final class ObjectService: Sendable {
    /// Bumped when classification changes: older results are redone.
    public static let version = 1
    static let minConfidence: Float = 0.15
    private static let visionLock = NSLock()

    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static let visible = "a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id)"

    /// Photos and videos not classified yet (newest first).
    public func pendingAssets(limit: Int? = nil) throws -> [String] {
        try db.writer.read {
            try String.fetchAll($0, sql: """
                SELECT id FROM asset WHERE missingSince IS NULL AND objectsVersion < ? ORDER BY takenAt DESC \(limit.map { "LIMIT \($0)" } ?? "")
                """, arguments: [Self.version])
        }
    }

    /// The confident labels for an image, best first.
    public static func classify(_ image: CGImage) throws -> [(name: String, confidence: Float)] {
        // serialised process-wide: concurrent Vision classifications can deadlock in Vision's task queue
        visionLock.lock(); defer { visionLock.unlock() }
        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .filter { $0.confidence >= minConfidence && $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            .sorted { $0.confidence > $1.confidence }
            .map { ($0.identifier, $0.confidence) }
    }

    public func store(assetId: String, labels: [(name: String, confidence: Float)]) throws {
        try db.writer.write { d in
            try d.execute(sql: "DELETE FROM asset_object WHERE assetId = ?", arguments: [assetId])
            for l in labels {
                try d.execute(sql: "INSERT OR IGNORE INTO object_label (name) VALUES (?)", arguments: [l.name])
                let id = try Int64.fetchOne(d, sql: "SELECT id FROM object_label WHERE name = ?", arguments: [l.name])!
                try d.execute(sql: "INSERT OR REPLACE INTO asset_object (assetId, labelId, confidence) VALUES (?, ?, ?)",
                              arguments: [assetId, id, Double(l.confidence)])
            }
            try d.execute(sql: "UPDATE asset SET objectsVersion = ? WHERE id = ?", arguments: [Self.version, assetId])
        }
    }

    /// Every label shown by at least one visible photo or video, most common first.
    public func labels() throws -> [ObjectLabel] {
        try db.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT l.id, l.name, COUNT(*) AS n,
                       (SELECT ao2.assetId FROM asset_object ao2 JOIN asset a2 ON a2.id = ao2.assetId
                         WHERE ao2.labelId = l.id AND a2.missingSince IS NULL
                           AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a2.id)
                         ORDER BY ao2.confidence DESC, a2.takenAt DESC LIMIT 1) AS cover
                FROM object_label l JOIN asset_object ao ON ao.labelId = l.id JOIN asset a ON a.id = ao.assetId
                WHERE \(Self.visible)
                GROUP BY l.id ORDER BY n DESC, l.name
                """).map { ObjectLabel(id: $0["id"], name: $0["name"], count: $0["n"], coverId: $0["cover"]) }
        }
    }

    /// A label and the photos and videos showing it (newest first).
    public func assets(labelId: Int64) throws -> (label: ObjectTag, ids: [String])? {
        try db.writer.read { d in
            guard let name = try String.fetchOne(d, sql: "SELECT name FROM object_label WHERE id = ?", arguments: [labelId]) else { return nil }
            let ids = try String.fetchAll(d, sql: """
                SELECT a.id FROM asset_object ao JOIN asset a ON a.id = ao.assetId
                WHERE ao.labelId = ? AND \(Self.visible) ORDER BY a.takenAt DESC
                """, arguments: [labelId])
            return (ObjectTag(id: labelId, name: name), ids)
        }
    }

    /// The labels of one photo, most confident first.
    static func tags(_ d: Database, assetId: String) throws -> [ObjectTag] {
        try Row.fetchAll(d, sql: """
            SELECT l.id, l.name FROM asset_object ao JOIN object_label l ON l.id = ao.labelId
            WHERE ao.assetId = ? ORDER BY ao.confidence DESC
            """, arguments: [assetId]).map { ObjectTag(id: $0["id"], name: $0["name"]) }
    }
}
