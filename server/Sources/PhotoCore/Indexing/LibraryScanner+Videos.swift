import Foundation
import GRDB

/// What a probe found in one library file.
enum MediaProbe {
    case image(ProbeResult)
    case video(VideoProbeResult, ext: String)   // ext lowercased

    static func isVideo(_ url: URL) -> Bool { LibraryScanner.videoExtensions.contains(url.pathExtension.lowercased()) }

    /// Videos via `VideoProbe` (blocks on AVFoundation: call from scanner threads only), everything else via ImageIO.
    static func probe(url: URL) -> MediaProbe? {
        if isVideo(url) { return VideoProbe.probe(url: url).map { .video($0, ext: url.pathExtension.lowercased()) } }
        return ImageProbe.probe(url: url).map(MediaProbe.image)
    }
}

extension LibraryScanner {
    /// Classifies each video: a Live Photo motion clip (same folder + basename as a still, or the same Apple
    /// content id) is attached to that still as a `motion` row; any other video is indexed as a video asset.
    func indexVideos(_ videos: [Candidate], existing: [String: FileRow], probeVersions: [String: Int],
                     folderIds: [String: Int64], dirEntries: inout [String: Set<String>], report: inout ScanReport,
                     tick: (Int) throws -> Void) throws {
        guard !videos.isEmpty else { return }
        let stills = try stillsByStem()
        var motionAt: [String: MotionRow] = [:]
        for m in try db.writer.read({ try MotionRow.filter(Column("root") == rootName).fetchAll($0) }) { motionAt[m.relPath] = m }

        for (i, v) in videos.enumerated() {
            try tick(i)
            let old = existing[v.relPath]
            let oldUnchanged = old.map { $0.size == v.size && $0.mtime == v.mtime } ?? false
            let oldCurrent = old.map { (probeVersions[$0.assetId] ?? 0) >= Asset.currentProbeVersion } ?? false

            if let m = motionAt[v.relPath], m.size == v.size, m.mtime == v.mtime, try isPresentPhoto(m.assetId) {
                continue   // unchanged motion clip: no probing
            }

            var probe: VideoProbeResult?
            var stillId = stills[stemKey(v.relPath)]
            if stillId == nil {
                let contentId: String?
                if let old, oldUnchanged, oldCurrent {
                    contentId = try db.writer.read { try String.fetchOne($0, sql: "SELECT contentId FROM asset WHERE id = ?", arguments: [old.assetId]) }
                } else {
                    probe = VideoProbe.probe(url: v.url)
                    contentId = probe?.contentId
                }
                if let contentId { stillId = try photo(withContentId: contentId) }
            }

            if let stillId {
                try attachMotion(v, to: stillId, probe: probe, old: old, previous: motionAt[v.relPath], report: &report)
                continue
            }

            if let m = motionAt[v.relPath] {
                try db.writer.write { d in
                    try m.delete(d)
                    try ChangeLog.record(d, entity: "asset", id: m.assetId, op: "upsert")
                }
            }
            if let old, oldUnchanged {
                if oldCurrent {
                    report.unchanged += 1
                } else if try refreshMetadata(old, url: v.url, mtime: v.mtime, dirEntries: &dirEntries) {
                    report.updated += 1
                } else {
                    report.skipped += 1
                    report.errors.append("Unreadable video: \(v.relPath)")
                }
                continue
            }
            if probe == nil { probe = VideoProbe.probe(url: v.url) }
            guard let probe else {
                report.skipped += 1
                report.errors.append("Unreadable video: \(v.relPath)")
                continue
            }
            switch try indexCandidate(v, old: old, folderId: folderIds[parentRel(v.relPath)]!, dirEntries: &dirEntries, video: probe) {
            case .indexed:
                if old == nil { report.added += 1 } else { report.updated += 1 }
            case .skipped(let why):
                report.skipped += 1
                report.errors.append(why)
            }
        }
    }

    /// Records `v` as the still's motion clip. A still keeps the first clip it got (Takeout duplicates);
    /// a video that used to be an asset loses its `file` row either way.
    private func attachMotion(_ v: Candidate, to stillId: String, probe: VideoProbeResult?, old: FileRow?,
                              previous: MotionRow?, report: inout ScanReport) throws {
        let taken = try db.writer.read { try MotionRow.fetchOne($0, key: stillId) }
        let duplicate = taken.map { $0.root != rootName || $0.relPath != v.relPath } ?? false
        var codec: String?
        if !duplicate {
            guard let p = probe ?? VideoProbe.probe(url: v.url) else {
                report.skipped += 1
                report.errors.append("Unreadable video: \(v.relPath)")
                return
            }
            codec = p.codec
        }
        try db.writer.write { d in
            if let previous, previous.assetId != stillId {
                try previous.delete(d)
                try ChangeLog.record(d, entity: "asset", id: previous.assetId, op: "upsert")
            }
            if !duplicate {
                try MotionRow(assetId: stillId, root: self.rootName, relPath: v.relPath, size: v.size, mtime: v.mtime, codec: codec)
                    .save(d)
                try ChangeLog.record(d, entity: "asset", id: stillId, op: "upsert")
            }
            if let old {
                try old.delete(d)
                try self.markMissingIfOrphaned(d, assetId: old.assetId)
            }
        }
        if !duplicate { report.liveMotion += 1 }
        if old != nil { report.removed += 1 }
    }

    /// Motion rows whose clip is no longer on disk (outside unreadable folders) are dropped.
    func removeVanishedMotion(present: Set<String>, keep: (String) -> Bool) throws {
        let rows = try db.writer.read { try MotionRow.filter(Column("root") == rootName).fetchAll($0) }
        let gone = rows.filter { !present.contains($0.relPath) && !keep($0.relPath) }
        guard !gone.isEmpty else { return }
        try db.writer.write { d in
            for m in gone {
                try m.delete(d)
                try ChangeLog.record(d, entity: "asset", id: m.assetId, op: "upsert")
            }
        }
    }

    /// Re-index: re-probe each motion clip of this root (size, mtime, codec); drop those that vanished.
    func refreshMotion(isCancelled: () -> Bool) throws {
        let rows = try db.writer.read { try MotionRow.filter(Column("root") == rootName).fetchAll($0) }
        for var m in rows {
            if isCancelled() { throw ScanError.cancelled }
            let url = root.appendingPathComponent(m.relPath)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let probe = attrs == nil ? nil : VideoProbe.probe(url: url)
            try db.writer.write { d in
                if let attrs, let probe {
                    m.size = (attrs[.size] as? NSNumber)?.int64Value ?? m.size
                    m.mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? m.mtime
                    m.codec = probe.codec
                    try m.update(d)
                } else {
                    try m.delete(d)
                }
                try ChangeLog.record(d, entity: "asset", id: m.assetId, op: "upsert")
            }
        }
    }

    /// "dir/lowercased-stem" → asset id of the first present photo with that name in this root.
    private func stillsByStem() throws -> [String: String] {
        let rows = try db.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT f.relPath, f.assetId FROM file f JOIN asset a ON a.id = f.assetId
                WHERE f.root = ? AND a.kind = 'photo' AND a.missingSince IS NULL ORDER BY f.relPath
                """, arguments: [rootName])
        }
        var out: [String: String] = [:]
        for r in rows {
            let key = stemKey(r["relPath"])
            if out[key] == nil { out[key] = r["assetId"] }
        }
        return out
    }

    private func stemKey(_ rel: String) -> String {
        parentRel(rel) + "/" + ((rel as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
    }

    private func isPresentPhoto(_ id: String) throws -> Bool {
        try db.writer.read {
            try Bool.fetchOne($0, sql: "SELECT 1 FROM asset WHERE id = ? AND kind = 'photo' AND missingSince IS NULL", arguments: [id]) ?? false
        }
    }

    private func photo(withContentId cid: String) throws -> String? {
        try db.writer.read {
            try String.fetchOne($0, sql: "SELECT id FROM asset WHERE contentId = ? AND kind = 'photo' AND missingSince IS NULL ORDER BY id LIMIT 1",
                                arguments: [cid])
        }
    }
}
