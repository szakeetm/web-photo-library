import Foundation
import CoreGraphics
import GRDB
import ImageIO
import UniformTypeIdentifiers

public struct CatalogPerson: Codable, Sendable, Equatable {
    public var id: Int64
    public var name: String?
    public var coverFaceId: Int64?
    public var count: Int
    public var hidden: Bool
}

public struct FaceInfo: Codable, Sendable, Equatable {
    public var id: Int64
    public var assetId: String
    public var personId: Int64?
    public var x: Double, y: Double, w: Double, h: Double
}

public enum PeopleError: Error, CustomStringConvertible {
    case notFound
    public var description: String { "Person or face not found." }
}

/// People: face detection results, automatic grouping, and the user's corrections.
/// - New faces join the closest person whose centroid is similar enough (never one that the face
///   was removed from).
/// - Faces that match nobody are clustered; groups of `minClusterSize` become unnamed people.
/// - User decisions ("user" assignments, rejections, names, hidden) are never undone by jobs.
public final class FaceService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Cosine similarity to a person's centroid needed to join them automatically.
    public static let assignThreshold: Float = 0.62
    /// Similarity for two unassigned faces to be neighbours when clustering.
    public static let clusterThreshold: Float = 0.62
    public static let minClusterSize = 3

    static func blob(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func vector(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }
    static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    // MARK: Scanning

    /// Assets that still need a face scan with the current analyzer.
    public func pendingAssets(limit: Int = .max) throws -> [String] {
        try db.writer.read {
            try String.fetchAll($0, sql: "SELECT id FROM asset WHERE missingSince IS NULL AND kind = 'photo' AND facesVersion < ? ORDER BY takenAt DESC LIMIT ?",
                                arguments: [FaceAnalyzer.version, limit])
        }
    }

    /// Stores the faces found in one photo (replacing an older scan's unassigned faces) and assigns them.
    public func store(assetId: String, faces: [DetectedFace]) throws {
        try db.writer.write { d in
            // Keep faces the user already named/assigned; drop the rest of an older scan.
            let keptUser = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM face WHERE assetId = ? AND assignment = 'user'", arguments: [assetId]) ?? 0
            if keptUser == 0 {
                try d.execute(sql: "DELETE FROM face WHERE assetId = ?", arguments: [assetId])
            }
            let centroids = try Self.centroids(d)
            if keptUser == 0 {
                for f in faces {
                    try d.execute(sql: "INSERT INTO face (assetId, x, y, w, h, quality, embedding) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                  arguments: [assetId, f.x, f.y, f.w, f.h, f.quality, Self.blob(f.embedding)])
                    let faceId = d.lastInsertedRowID
                    if let p = Self.bestPerson(for: f.embedding, centroids: centroids, rejected: []) {
                        try d.execute(sql: "UPDATE face SET personId = ?, assignment = 'auto' WHERE id = ?", arguments: [p, faceId])
                    }
                }
            }
            try d.execute(sql: "UPDATE asset SET facesVersion = ? WHERE id = ?", arguments: [FaceAnalyzer.version, assetId])
            if !faces.isEmpty {
                try ChangeLog.record(d, entity: "asset", id: assetId, op: "upsert")
                try ChangeLog.record(d, entity: "person", id: "*", op: "upsert")
            }
        }
    }

    static func centroids(_ d: Database) throws -> [Int64: [Float]] {
        var sums: [Int64: [Float]] = [:]
        for r in try Row.fetchAll(d, sql: """
            SELECT f.personId, f.embedding FROM face f JOIN person p ON p.id = f.personId WHERE p.hidden = 0
            """) {
            let v = vector(r["embedding"])
            let id: Int64 = r["personId"]
            if var s = sums[id] {
                for i in 0..<min(s.count, v.count) { s[i] += v[i] }
                sums[id] = s
            } else {
                sums[id] = v
            }
        }
        return sums.mapValues(normalized)
    }

    static func bestPerson(for v: [Float], centroids: [Int64: [Float]], rejected: Set<Int64>) -> Int64? {
        var best: (Int64, Float)?
        for (id, c) in centroids where !rejected.contains(id) {
            let s = dot(v, c)
            if s >= assignThreshold, s > (best?.1 ?? -1) { best = (id, s) }
        }
        return best?.0
    }

    /// Groups faces that belong to nobody: re-tries existing people first, then clusters the rest
    /// (DBSCAN-style) into new unnamed people. Unnamed people the user never touched are rebuilt.
    @discardableResult
    public func cluster() throws -> Int {
        try db.writer.write { d in
            // Who each face belongs to before, so only photos whose people change are re-sent to clients.
            var before: [Int64: (asset: String, person: Int64?)] = [:]
            for r in try Row.fetchAll(d, sql: "SELECT id, assetId, personId FROM face") { before[r["id"]] = (r["assetId"], r["personId"]) }
            // Rebuild automatic unnamed groups from scratch (so they improve as photos are added).
            let rebuilt = Set(try Int64.fetchAll(d, sql: """
                SELECT id FROM person WHERE name IS NULL AND hidden = 0
                  AND NOT EXISTS (SELECT 1 FROM face WHERE personId = person.id AND assignment = 'user')
                """))
            try d.execute(sql: """
                DELETE FROM person WHERE name IS NULL AND hidden = 0
                  AND NOT EXISTS (SELECT 1 FROM face WHERE personId = person.id AND assignment = 'user')
                  AND NOT EXISTS (SELECT 1 FROM face_reject WHERE personId = person.id)
                """)
            try d.execute(sql: "UPDATE face SET assignment = NULL WHERE personId IS NULL AND assignment = 'auto'")
            let centroids = try Self.centroids(d)
            let rows = try Row.fetchAll(d, sql: """
                SELECT f.id, f.embedding, (SELECT group_concat(personId) FROM face_reject r WHERE r.faceId = f.id) AS rejected
                FROM face f JOIN asset a ON a.id = f.assetId
                WHERE f.personId IS NULL AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id)
                ORDER BY f.quality DESC
                """)
            var pool: [(id: Int64, v: [Float], rejected: Set<Int64>)] = rows.map {
                ($0["id"], Self.vector($0["embedding"]),
                 Set((($0["rejected"] as String?) ?? "").split(separator: ",").compactMap { Int64($0) }))
            }
            // 1. faces that now match an existing person
            var remaining: [(id: Int64, v: [Float], rejected: Set<Int64>)] = []
            for f in pool {
                if let p = Self.bestPerson(for: f.v, centroids: centroids, rejected: f.rejected) {
                    try d.execute(sql: "UPDATE face SET personId = ?, assignment = 'auto' WHERE id = ?", arguments: [p, f.id])
                } else {
                    remaining.append(f)
                }
            }
            pool = remaining
            // 2. Group the rest (chunked DBSCAN, see FaceClustering)
            let clusters = FaceClustering.cluster(pool.map(\.v), threshold: Self.clusterThreshold, minPoints: Self.minClusterSize)
            var created = 0
            var reused = Set<Int64>()
            for members in clusters.sorted(by: { $0.count > $1.count }) where members.count >= Self.minClusterSize {
                // A group that is mostly an earlier unnamed person keeps that person's id (stable for clients).
                var votes: [Int64: Int] = [:]
                for m in members { if let p = before[pool[m].id]?.person, rebuilt.contains(p), !reused.contains(p) { votes[p, default: 0] += 1 } }
                let pid: Int64
                if let (old, n) = votes.max(by: { $0.value < $1.value }), n * 2 > members.count {
                    try d.execute(sql: "INSERT INTO person (id, name, hidden, createdAt) VALUES (?, NULL, 0, ?)", arguments: [old, Date()])
                    pid = old
                    reused.insert(old)
                } else {
                    try d.execute(sql: "INSERT INTO person (name, hidden, createdAt) VALUES (NULL, 0, ?)", arguments: [Date()])
                    pid = d.lastInsertedRowID
                }
                for m in members {
                    try d.execute(sql: "UPDATE face SET personId = ?, assignment = 'auto' WHERE id = ?", arguments: [pid, pool[m].id])
                }
                created += 1
            }
            var changed = Set<String>()
            for r in try Row.fetchAll(d, sql: "SELECT id, assetId, personId FROM face") {
                let id: Int64 = r["id"], person: Int64? = r["personId"]
                if before[id]?.person != person { changed.insert(r["assetId"]) }
            }
            for asset in changed { try ChangeLog.record(d, entity: "asset", id: asset, op: "upsert") }
            try ChangeLog.record(d, entity: "person", id: "*", op: "upsert")
            return created
        }
    }

    /// Faces changed in bulk: every asset with faces and the people list must be re-sent to clients.
    static func touchAll(_ d: Database) throws {
        for id in try String.fetchAll(d, sql: "SELECT DISTINCT assetId FROM face") {
            try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
        }
        try ChangeLog.record(d, entity: "person", id: "*", op: "upsert")
    }

    static func touchAssets(_ d: Database, faceIds: [Int64]? = nil, personId: Int64? = nil) throws {
        var ids: [String] = []
        if let faceIds {
            ids += try String.fetchAll(d, sql: "SELECT DISTINCT assetId FROM face WHERE id IN (SELECT value FROM json_each(?))",
                                       arguments: [String(decoding: try JSONEncoder().encode(faceIds), as: UTF8.self)])
        }
        if let personId {
            ids += try String.fetchAll(d, sql: "SELECT DISTINCT assetId FROM face WHERE personId = ?", arguments: [personId])
        }
        for id in Set(ids) { try ChangeLog.record(d, entity: "asset", id: id, op: "upsert") }
        try ChangeLog.record(d, entity: "person", id: "*", op: "upsert")
    }

    // MARK: Queries

    public static func catalogPeople(_ d: Database) throws -> [CatalogPerson] {
        try Row.fetchAll(d, sql: """
            SELECT p.id, p.name, p.hidden,
                   (SELECT COUNT(DISTINCT f.assetId) FROM face f JOIN asset a ON a.id = f.assetId
                     WHERE f.personId = p.id AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id)) AS count,
                   COALESCE((SELECT f.id FROM face f WHERE f.id = p.coverFaceId AND f.personId = p.id),
                            (SELECT f.id FROM face f JOIN asset a ON a.id = f.assetId
                              WHERE f.personId = p.id AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id) ORDER BY f.quality DESC LIMIT 1)) AS cover
            FROM person p
            """).compactMap { r -> CatalogPerson? in
            let count: Int = r["count"]
            guard count > 0 else { return nil }
            return CatalogPerson(id: r["id"], name: r["name"], coverFaceId: r["cover"], count: count, hidden: r["hidden"])
        }.sorted { a, b in
            // named first (by size), then unnamed by size
            if (a.name == nil) != (b.name == nil) { return a.name != nil }
            return a.count != b.count ? a.count > b.count : a.id < b.id
        }
    }

    public func people() throws -> [CatalogPerson] { try db.writer.read { try Self.catalogPeople($0) } }

    public func faces(assetId: String) throws -> [FaceInfo] {
        try db.writer.read {
            try Row.fetchAll($0, sql: "SELECT id, assetId, personId, x, y, w, h FROM face WHERE assetId = ? ORDER BY x", arguments: [assetId]).map(Self.info)
        }
    }

    public func faces(personId: Int64) throws -> [FaceInfo] {
        try db.writer.read {
            try Row.fetchAll($0, sql: """
                SELECT f.id, f.assetId, f.personId, f.x, f.y, f.w, f.h FROM face f JOIN asset a ON a.id = f.assetId
                WHERE f.personId = ? AND a.missingSince IS NULL AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id) ORDER BY a.takenAt DESC
                """, arguments: [personId]).map(Self.info)
        }
    }

    static func info(_ r: Row) -> FaceInfo {
        FaceInfo(id: r["id"], assetId: r["assetId"], personId: r["personId"], x: r["x"], y: r["y"], w: r["w"], h: r["h"])
    }

    public func face(id: Int64) throws -> FaceInfo? {
        try db.writer.read { try Row.fetchOne($0, sql: "SELECT id, assetId, personId, x, y, w, h FROM face WHERE id = ?", arguments: [id]).map(Self.info) }
    }

    // MARK: User actions

    public func update(personId: Int64, name: String??, hidden: Bool?, coverFaceId: Int64?) throws {
        try db.writer.write { d in
            guard try Int.fetchOne(d, sql: "SELECT 1 FROM person WHERE id = ?", arguments: [personId]) != nil else { throw PeopleError.notFound }
            if let name {
                let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
                try d.execute(sql: "UPDATE person SET name = ? WHERE id = ?", arguments: [n?.isEmpty == false ? n : nil, personId])
                // Naming confirms the group: its faces stay with this person.
                if n?.isEmpty == false {
                    try d.execute(sql: "UPDATE face SET assignment = 'user' WHERE personId = ? AND assignment = 'auto'", arguments: [personId])
                }
            }
            if let hidden { try d.execute(sql: "UPDATE person SET hidden = ? WHERE id = ?", arguments: [hidden, personId]) }
            if let coverFaceId { try d.execute(sql: "UPDATE person SET coverFaceId = ? WHERE id = ?", arguments: [coverFaceId, personId]) }
            try Self.touchAssets(d, personId: personId)
        }
    }

    /// Moves every face of `sources` to `target` (e.g. two groups that are the same person).
    public func merge(sources: [Int64], into target: Int64) throws {
        try db.writer.write { d in
            guard let targetName = try Row.fetchOne(d, sql: "SELECT name FROM person WHERE id = ?", arguments: [target]) else { throw PeopleError.notFound }
            let named = (targetName["name"] as String?) != nil
            for s in sources where s != target {
                try Self.touchAssets(d, personId: s)
                try d.execute(sql: "UPDATE face SET personId = ?, assignment = ? WHERE personId = ?",
                              arguments: [target, named ? "user" : "auto", s])
                try d.execute(sql: "DELETE FROM person WHERE id = ?", arguments: [s])
            }
            try Self.touchAssets(d, personId: target)
        }
    }

    /// Assigns a face to a person (user decision), or removes it from its person (`nil`): a removed
    /// face is never put back into that person automatically.
    public func assign(faceId: Int64, to personId: Int64?) throws {
        try db.writer.write { d in
            guard let current = try Row.fetchOne(d, sql: "SELECT personId FROM face WHERE id = ?", arguments: [faceId]) else { throw PeopleError.notFound }
            let old: Int64? = current["personId"]
            if let personId {
                guard try Int.fetchOne(d, sql: "SELECT 1 FROM person WHERE id = ?", arguments: [personId]) != nil else { throw PeopleError.notFound }
                try d.execute(sql: "DELETE FROM face_reject WHERE faceId = ? AND personId = ?", arguments: [faceId, personId])
                try d.execute(sql: "UPDATE face SET personId = ?, assignment = 'user' WHERE id = ?", arguments: [personId, faceId])
            } else {
                if let old { try d.execute(sql: "INSERT OR IGNORE INTO face_reject (faceId, personId) VALUES (?, ?)", arguments: [faceId, old]) }
                try d.execute(sql: "UPDATE face SET personId = NULL, assignment = 'user' WHERE id = ?", arguments: [faceId])
            }
            try Self.touchAssets(d, faceIds: [faceId])
        }
    }

    /// Creates a named person from a face (e.g. naming a face that belongs to nobody).
    public func createPerson(name: String, faceIds: [Int64]) throws -> Int64 {
        let id = try db.writer.write { d -> Int64 in
            try d.execute(sql: "INSERT INTO person (name, hidden, createdAt) VALUES (?, 0, ?)", arguments: [name, Date()])
            return d.lastInsertedRowID
        }
        for f in faceIds { try assign(faceId: f, to: id) }
        return id
    }

    // MARK: Face thumbnails

    /// Square crop around a face from the unedited preview, cached on disk.
    public func thumbnail(faceId: Int64, preview: URL, cacheDir: URL) throws -> URL {
        guard let f = try face(id: faceId) else { throw PeopleError.notFound }
        let target = cacheDir.appendingPathComponent("faces/\(faceId).jpg")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let image = try DerivativeStore.downscaled(source: preview, maxPixel: DerivativeKind.preview.maxPixel)
        let W = Double(image.width), H = Double(image.height)
        let side = min(max(f.w * W, f.h * H) * 1.6, min(W, H))
        let cx = (f.x + f.w / 2) * W, cy = (f.y + f.h / 2) * H
        let rect = CGRect(x: min(max(0, cx - side / 2), W - side), y: min(max(0, cy - side / 2), H - side), width: side, height: side).integral
        guard let crop = image.cropping(to: rect) else { throw PeopleError.notFound }
        let out = try DerivativeStore.downscaled(image: crop, maxPixel: 256)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw PeopleError.notFound }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PeopleError.notFound }
        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        return target
    }
}
