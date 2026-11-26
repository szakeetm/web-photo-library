import CoreGraphics
import CryptoKit
import Foundation
import GRDB
import Vision

/// A set of photos that look like the same picture ("same": re-saved, resized or converted copies)
/// or nearly so ("similar": bursts and crops taken within a couple of minutes).
public struct DuplicateGroup: Codable, Sendable, Equatable {
    public var key: String
    public var kind: String
    public var items: [DuplicateItem]
}

public struct DuplicateItem: Codable, Sendable, Equatable {
    public var id: String
    public var w: Int
    public var h: Int
    public var t: String
    public var tz: Int?
    public var bytes: Int64
    public var mime: String
    public var path: String
    /// "library" or "uploads": only uploads can be moved to the Trash.
    public var root: String
    public var fav: Bool
    public var albums: Int
}

/// Image fingerprints (a 64-bit difference hash and Vision's feature print) and the duplicate groups
/// they reveal. Photos are never deleted here: uploads go to the Trash and library copies are shown
/// in the Finder, from the web app.
public final class DuplicateService: @unchecked Sendable {
    /// Bumped when fingerprints change: older ones are redone.
    public static let version = 1
    /// dHash bits that may differ for "same" (≤ 3: one of four 16-bit chunks always matches).
    static let sameHamming = 3
    /// Feature print distance (Euclidean, Vision revision 2): a resized, re-compressed copy ≈ 0.25,
    /// a crop ≈ 0.5, different photos of one trip ≥ 0.85.
    static let sameDistance: Float = 0.4
    static let similarDistance: Float = 0.6
    static let similarWindow: TimeInterval = 120
    /// Buckets this large are flat images (black frames, blank pages), not duplicates.
    static let maxBucket = 400

    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    // MARK: Fingerprints

    /// 64-bit difference hash: each bit says whether a pixel of a 9×8 grey thumbnail is darker than its right neighbour.
    public static func dhash(_ image: CGImage) -> UInt64 {
        let ctx = CGContext(data: nil, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var h: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                h <<= 1
                if p[y * 9 + x] < p[y * 9 + x + 1] { h |= 1 }
            }
        }
        return h
    }

    /// Vision's feature print, as half floats (768 values in revision 2).
    public static func featurePrint(_ image: CGImage) throws -> [Float16] {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let o = request.results?.first, o.elementType == .float else { return [] }
        return o.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)).map(Float16.init) }
    }

    static func distance(_ a: [Float16], _ b: [Float16]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var s: Float = 0
        for i in 0..<a.count {
            let d = Float(a[i]) - Float(b[i])
            s += d * d
        }
        return s.squareRoot()
    }

    /// Stores a photo's fingerprints; nil (videos, unreadable files) only marks it done.
    public func store(assetId: String, dhash: UInt64?, print: [Float16]) throws {
        try db.writer.write { d in
            if let dhash, !print.isEmpty {
                let data = print.withUnsafeBufferPointer { Data(buffer: $0) }
                try d.execute(sql: "INSERT OR REPLACE INTO asset_print (assetId, dhash, print) VALUES (?, ?, ?)",
                              arguments: [assetId, Int64(bitPattern: dhash), data])
            } else {
                try d.execute(sql: "DELETE FROM asset_print WHERE assetId = ?", arguments: [assetId])
            }
            try d.execute(sql: "UPDATE asset SET printVersion = ? WHERE id = ?", arguments: [Self.version, assetId])
        }
    }

    // MARK: Groups

    struct Entry {
        let id: String
        let dhash: UInt64
        let print: [Float16]
        let taken: Date
        let aspect: Double
    }

    private let lock = NSLock()
    private var cache: (seq: Int64, groups: [DuplicateGroup])?

    /// Duplicate groups (photos only, none dismissed), "same" ones first, newest first within each kind.
    public func groups() throws -> [DuplicateGroup] {
        let seq = try db.writer.read { try Int64.fetchOne($0, sql: "SELECT MAX(seq) FROM change_log") ?? 0 }
        lock.lock()
        if let c = cache, c.seq == seq { lock.unlock(); return c.groups }
        lock.unlock()
        let groups = try compute()
        lock.lock(); cache = (seq, groups); lock.unlock()
        return groups
    }

    func compute() throws -> [DuplicateGroup] {
        let entries: [Entry] = try db.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT a.id, p.dhash, p.print, a.takenAt, a.width, a.height FROM asset_print p JOIN asset a ON a.id = p.assetId
                WHERE a.missingSince IS NULL AND a.kind = 'photo' AND NOT EXISTS (SELECT 1 FROM trash tr WHERE tr.assetId = a.id)
                ORDER BY a.takenAt
                """).map { r in
                let data: Data = r["print"]
                let print = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
                let w: Int = r["width"], h: Int = r["height"]
                return Entry(id: r["id"], dhash: UInt64(bitPattern: r["dhash"]), print: print, taken: r["takenAt"],
                             aspect: h > 0 ? Double(w) / Double(h) : 1)
            }
        }
        var same = UnionFind(entries.count)
        var similar = UnionFind(entries.count)

        // Same picture: candidates share one 16-bit chunk of the hash (pigeonhole for ≤ 3 differing bits).
        var checked = Set<Int64>()
        for chunk in 0..<4 {
            var buckets: [UInt16: [Int]] = [:]
            for (i, e) in entries.enumerated() { buckets[UInt16(truncatingIfNeeded: e.dhash >> (chunk * 16)), default: []].append(i) }
            for list in buckets.values where list.count > 1 && list.count <= Self.maxBucket {
                for x in 0..<list.count {
                    for y in (x + 1)..<list.count {
                        let i = list[x], j = list[y]
                        guard checked.insert(Int64(i) << 32 | Int64(j)).inserted else { continue }
                        let a = entries[i], b = entries[j]
                        if (a.dhash ^ b.dhash).nonzeroBitCount <= Self.sameHamming,
                           abs(a.aspect - b.aspect) / max(a.aspect, b.aspect) < 0.03,
                           Self.distance(a.print, b.print) < Self.sameDistance {
                            same.union(i, j)
                        }
                    }
                }
            }
        }
        // Nearly the same, taken close together (bursts, crops): compare within a sliding time window.
        var start = 0
        for j in 0..<entries.count {
            while entries[j].taken.timeIntervalSince(entries[start].taken) > Self.similarWindow { start += 1 }
            for i in start..<j where Self.distance(entries[i].print, entries[j].print) < Self.similarDistance {
                similar.union(i, j)
            }
        }

        let dismissed = Set(try db.writer.read { try String.fetchAll($0, sql: "SELECT groupKey FROM duplicate_dismiss") })
        let sameSets = same.sets().map { Set($0.map { entries[$0].id }) }
        let sameKeys = Set(sameSets)
        var out: [(kind: String, ids: Set<String>)] = sameSets.map { ("same", $0) }
        for s in similar.sets() {
            let ids = Set(s.map { entries[$0].id })
            if !sameKeys.contains(ids) { out.append(("similar", ids)) }
        }
        let groups = out.compactMap { g -> (String, String, Set<String>)? in
            let key = Self.key(kind: g.kind, ids: g.ids)
            return dismissed.contains(key) ? nil : (key, g.kind, g.ids)
        }
        let details = try items(ids: groups.flatMap { $0.2 })
        return groups.map { key, kind, ids in
            DuplicateGroup(key: key, kind: kind, items: ids.compactMap { details[$0] }.sorted { $0.t < $1.t || ($0.t == $1.t && $0.id < $1.id) })
        }
        .filter { $0.items.count > 1 }
        .sorted { ($0.kind == "same" ? 0 : 1, $1.items.last?.t ?? "") < ($1.kind == "same" ? 0 : 1, $0.items.last?.t ?? "") }
    }

    /// Stable id of a group: its kind and members (a new member makes it a new group, shown again).
    static func key(kind: String, ids: Set<String>) -> String {
        let digest = SHA256.hash(data: Data(ids.sorted().joined(separator: ",").utf8))
        return kind.prefix(1) + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func items(ids: [String]) throws -> [String: DuplicateItem] {
        guard !ids.isEmpty else { return [:] }
        let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        return try db.writer.read { d in
            var out: [String: DuplicateItem] = [:]
            for r in try Row.fetchAll(d, sql: """
                SELECT a.id, a.width, a.height, a.takenAt, a.tzOffset, a.mime, a.favorite,
                       (SELECT COUNT(*) FROM album_asset aa WHERE aa.assetId = a.id) AS albums,
                       f.size, f.relPath, f.root
                FROM asset a JOIN file f ON f.id = (SELECT f2.id FROM file f2 WHERE f2.assetId = a.id
                                                    ORDER BY f2.root = 'uploads', f2.relPath LIMIT 1)
                WHERE a.id IN (SELECT value FROM json_each(?))
                """, arguments: [json]) {
                let id: String = r["id"]
                out[id] = DuplicateItem(id: id, w: r["width"], h: r["height"],
                                        t: CatalogService.iso.string(from: r["takenAt"]), tz: r["tzOffset"],
                                        bytes: r["size"], mime: r["mime"], path: r["relPath"], root: r["root"],
                                        fav: r["favorite"], albums: r["albums"])
            }
            return out
        }
    }

    /// "Not duplicates": the group isn't shown again (unless its members change).
    public func dismiss(key: String) throws {
        try db.writer.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO duplicate_dismiss (groupKey, createdAt) VALUES (?, ?)", arguments: [key, Date()])
            try ChangeLog.record(d, entity: "duplicates", id: key, op: "upsert")
        }
    }

    /// The kept photo gets the others' albums and favourite, before they are removed.
    public func merge(keep: String, others: [String]) throws {
        let others = others.filter { $0 != keep }
        guard !others.isEmpty else { return }
        let json = String(decoding: try JSONEncoder().encode(others), as: UTF8.self)
        try db.writer.write { d in
            guard try Asset.fetchOne(d, key: keep) != nil else { return }
            try ChangeLog.recordAlbums(d, containing: others)
            try d.execute(sql: """
                INSERT OR IGNORE INTO album_asset (albumId, assetId, position)
                SELECT albumId, ?, MIN(position) FROM album_asset WHERE assetId IN (SELECT value FROM json_each(?)) GROUP BY albumId
                """, arguments: [keep, json])
            if try Bool.fetchOne(d, sql: "SELECT EXISTS (SELECT 1 FROM asset WHERE favorite = 1 AND id IN (SELECT value FROM json_each(?)))",
                                 arguments: [json]) == true {
                try d.execute(sql: "UPDATE asset SET favorite = 1, favoriteUserSet = 1 WHERE id = ?", arguments: [keep])
            }
            try ChangeLog.recordAlbums(d, containing: [keep])
            try ChangeLog.record(d, entity: "asset", id: keep, op: "upsert")
        }
    }
}

/// Disjoint sets over 0..<n (path halving).
struct UnionFind {
    var parent: [Int]
    init(_ n: Int) { parent = Array(0..<n) }
    mutating func find(_ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
    }
    /// Sets with more than one member.
    mutating func sets() -> [[Int]] {
        var by: [Int: [Int]] = [:]
        for i in 0..<parent.count { by[find(i), default: []].append(i) }
        return by.values.filter { $0.count > 1 }
    }
}
