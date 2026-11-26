import Foundation
import CoreGraphics
import CoreImage
import GRDB
import ImageIO
import UniformTypeIdentifiers

public struct EditVersion: Codable, Sendable, Equatable {
    public var version: Int
    public var recipe: EditRecipe
    public var createdAt: Date
}

public struct EditHistory: Codable, Sendable, Equatable {
    /// 0 = unedited.
    public var current: Int
    public var versions: [EditVersion]
}

public enum EditError: Error, CustomStringConvertible {
    case notFound, sourceUnavailable
    public var description: String {
        switch self {
        case .notFound: "Photo not found."
        case .sourceUnavailable: "The original file isn't available (moved or changed since the last scan)."
        }
    }
}

/// Edit history (append-only), edited renders, auto-enhance and exports.
public final class EditService: Sendable {
    let db: AppDatabase
    let catalog: CatalogService
    let derivatives: @Sendable () -> DerivativeStore

    public init(db: AppDatabase, catalog: CatalogService, derivatives: @escaping @Sendable () -> DerivativeStore) {
        self.db = db
        self.catalog = catalog
        self.derivatives = derivatives
    }

    static func decode(_ json: String) throws -> EditRecipe {
        try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
    }

    static func encode(_ r: EditRecipe) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(r), as: UTF8.self)
    }

    public func history(id: String) throws -> EditHistory? {
        try db.writer.read { d in
            guard let a = try Asset.fetchOne(d, key: id) else { return nil }
            let rows = try Row.fetchAll(d, sql: "SELECT version, recipe, createdAt FROM edit WHERE assetId = ? ORDER BY version", arguments: [id])
            return EditHistory(current: a.editVersion, versions: try rows.map {
                EditVersion(version: $0["version"], recipe: try Self.decode($0["recipe"]), createdAt: $0["createdAt"])
            })
        }
    }

    public func recipe(id: String, version: Int) throws -> EditRecipe? {
        try db.writer.read { try Self.recipe($0, id: id, version: version) }
    }

    static func recipe(_ d: Database, id: String, version: Int) throws -> EditRecipe? {
        try String.fetchOne(d, sql: "SELECT recipe FROM edit WHERE assetId = ? AND version = ?", arguments: [id, version]).map(decode)
    }

    /// Appends `recipe` as the new current version (an identity recipe reverts instead) and renders
    /// the edited preview + thumbnail, so viewing never needs the editor.
    public func save(id: String, recipe: EditRecipe) throws -> CatalogAsset {
        let r = try recipe.validated().normalized()
        if r.isIdentity { return try revert(id: id) }
        guard let source = try catalog.sourceURL(id: id) else { throw EditError.sourceUnavailable }
        let version = try db.writer.write { d -> Int in
            guard try Asset.fetchOne(d, key: id) != nil else { throw EditError.notFound }
            let v = try Self.nextVersion(d)
            try d.execute(sql: "INSERT INTO edit (assetId, version, recipe, createdAt) VALUES (?, ?, ?, ?)",
                          arguments: [id, v, try Self.encode(r), Date()])
            return v
        }
        // Render before switching the current version, so clients never see a version without images.
        try ensureRendered(id: id, version: version, recipe: r, source: source)
        try setCurrent(id: id, version: version)
        guard let asset = try catalog.catalogAsset(id: id) else { throw EditError.notFound }
        return asset
    }

    public func revert(id: String) throws -> CatalogAsset {
        try setCurrent(id: id, version: 0)
        guard let asset = try catalog.catalogAsset(id: id) else { throw EditError.notFound }
        return asset
    }

    private func setCurrent(id: String, version: Int) throws {
        let store = derivatives()
        let thumb = store.url(id: id, kind: .thumb, editVersion: version, format: .heic)
        let bh = (try? DerivativeStore.downscaled(source: thumb, maxPixel: 64)).map { BlurHash.encode(cgImage: $0) }
        try db.writer.write { d in
            guard try Asset.fetchOne(d, key: id) != nil else { throw EditError.notFound }
            // Overlapping saves (two devices) finish in any order: never step back to an older version.
            try d.execute(sql: """
                UPDATE asset SET editVersion = ?, blurhash = COALESCE(?, blurhash)
                WHERE id = ? AND (? = 0 OR editVersion < ?)
                """, arguments: [version, bh, id, version, version])
            try ChangeLog.record(d, entity: "asset", id: id, op: "upsert")
        }
    }

    // MARK: Rendering

    /// Edited preview (≤ 2048 px long edge after the crop) and thumbnail for one version, both formats.
    public func ensureRendered(id: String, version: Int, recipe: EditRecipe, source: URL, formats: [ImageFormat] = ImageFormat.allCases) throws {
        let store = derivatives()
        let missing = formats.filter { !store.exists(id: id, kind: .preview, editVersion: version, format: $0) || !store.exists(id: id, kind: .thumb, editVersion: version, format: $0) }
        guard !missing.isEmpty else { return }
        let (edited, hdr) = try renderPreview(id: id, source: source, recipe: recipe)
        for f in missing { try store.storeEdited(edited, hdr: hdr, id: id, version: version, format: f) }
    }

    /// Decodes the original at the size the crop needs for a sharp 2048 px preview, then runs the recipe.
    func renderPreview(id: String, source: URL, recipe: EditRecipe) throws -> (CGImage, HDRMetadata) {
        let crop = recipe.crop ?? .full
        let want = Int((Double(DerivativeKind.preview.maxPixel) / max(crop.w, crop.h, 0.05)).rounded(.up))
        let base = try DerivativeStore.downscaled(source: source, maxPixel: min(want, 8192))
        // The editor's own gain map, so the saved preview matches what the editor showed.
        let (out, hdr) = try render(base, source: source, recipe: recipe) { try self.derivatives().gainMap(id: id, source: source) }
        // A crop of a small original can't reach 2048; a large one may slightly exceed it.
        if max(out.width, out.height) > DerivativeKind.preview.maxPixel {
            return (try DerivativeStore.downscaled(image: out, maxPixel: DerivativeKind.preview.maxPixel), hdr)
        }
        return (out, hdr)
    }

    /// Full-resolution edited image (orientation applied) and its HDR gain maps.
    public func renderFull(id: String, version: Int) throws -> CGImage {
        try renderFullHDR(id: id, version: version).0
    }

    func renderFullHDR(id: String, version: Int) throws -> (CGImage, HDRMetadata) {
        guard let recipe = try recipe(id: id, version: version) else { throw EditError.notFound }
        guard let source = try catalog.sourceURL(id: id) else { throw EditError.sourceUnavailable }
        let full = try DerivativeStore.downscaled(source: source, maxPixel: 16384)
        return try render(full, source: source, recipe: recipe) {
            try NormalizedGainMap.make(source: source, maxPixel: min(2048, max(full.width, full.height) / 2))
        }
    }

    /// Runs `recipe` over `base` (the SDR decode of `source`). An HDR original keeps HDR: geometry-only
    /// edits carry its own gain map through the same geometry; other edits render the HDR rendition too
    /// and get a gain map computed from the two. SDR originals stay SDR.
    func render(_ base: CGImage, source: URL, recipe: EditRecipe,
                gainMap: () throws -> NormalizedGainMap?) throws -> (CGImage, HDRMetadata) {
        let renderer = try EditRenderer.shared()
        if recipe.isGeometryOnly {
            return (try renderer.render(base, recipe: recipe), try HDRMetadata.geometry(of: source, recipe: recipe, renderer: renderer))
        }
        guard let map = try gainMap() else { return (try renderer.render(base, recipe: recipe), .none) }
        let (sdr, hdr) = try renderer.renderHDR(base, gainMap: map, recipe: recipe)
        return (sdr, try HDRMetadata.derived(sdr: sdr, hdr: hdr))
    }

    // MARK: Export

    public enum ExportVariant: String, Sendable { case original, edited }

    /// A full-resolution file to download/share: the current edit rendered at full size with the
    /// original's metadata (orientation normalised) and the adjusted date, if any. Recent exports are kept.
    public func export(id: String, format: ImageFormat) throws -> (url: URL, filename: String) {
        guard let detail = try catalog.asset(id: id) else { throw EditError.notFound }
        let version = detail.asset.editVersion
        guard version > 0 else { throw EditError.notFound }
        guard let source = try catalog.sourceURL(id: id) else { throw EditError.sourceUnavailable }
        let dir = derivatives().cacheDir.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let userDate = detail.asset.dateSource == "user" ? (detail.asset.takenAt, detail.asset.tzOffset) : nil
        // "_l": exports that keep the Live Photo pairing (older cached exports lack it); "_d…": the adjusted date
        let dated = userDate.map { "_d\(Int($0.0.timeIntervalSince1970))_\($0.1 ?? 0)" } ?? ""
        let target = dir.appendingPathComponent("\(id)_e\(version)_l\(dated).\(format.rawValue)")
        let base = (source.lastPathComponent as NSString).deletingPathExtension
        let filename = "\(base)-edited.\(format == .heic ? "heic" : "jpg")"
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return (target, filename)
        }
        let (image, hdr) = try renderFullHDR(id: id, version: version)
        try Self.write(image, hdr: hdr, to: target, format: format, metadataFrom: source, date: userDate)
        Self.pruneExports(in: dir, keep: 12)
        return (target, filename)
    }

    static func write(_ image: CGImage, hdr: HDRMetadata = .none, to target: URL, format: ImageFormat, metadataFrom source: URL,
                      date: (Date, Int?)? = nil) throws {
        var props: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithURL(source as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
                if var dict = p[key] as? [CFString: Any] {
                    dict.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                    dict.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                    dict.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                    props[key] = dict
                }
            }
        }
        // Keep a Live Photo's content identifier (Apple maker note, key 17): Photos pairs the edited
        // still with the original motion clip when both are imported together.
        if let src = CGImageSourceCreateWithURL(source as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let apple = p[kCGImagePropertyMakerAppleDictionary] as? [String: Any], let cid = apple["17"] {
            props[kCGImagePropertyMakerAppleDictionary] = ["17": cid]
        }
        if let date { MetadataRewriter.dateProperties(date.0, tzOffset: date.1, into: &props) }
        for (k, v) in hdr.imageProperties { props[k] = v }
        props[kCGImagePropertyOrientation] = 1
        props[kCGImageDestinationLossyCompressionQuality] = format == .heic ? 0.85 : 0.92
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, (format == .heic ? UTType.heic : UTType.jpeg).identifier as CFString, 1, nil) else {
            throw DerivativeError.encodeFailed(target.path)
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        for map in hdr.gainMaps { CGImageDestinationAddAuxiliaryDataInfo(dest, map.type, map.info as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw DerivativeError.encodeFailed(target.path)
        }
        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
    }

    static func pruneExports(in dir: URL, keep: Int) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for f in files.dropFirst(keep) { try? fm.removeItem(at: f) }
    }

    // MARK: Auto-enhance

    /// Core Image's analysis of the photo, expressed as recipe values (not saved).
    public func autoEnhance(id: String) throws -> EditRecipe {
        guard let source = try catalog.sourceURL(id: id) else { throw EditError.sourceUnavailable }
        let base = try DerivativeStore.downscaled(source: source, maxPixel: 1024)
        return Self.autoRecipe(for: CIImage(cgImage: base))
    }

    static func autoRecipe(for image: CIImage) -> EditRecipe {
        var r = EditRecipe()
        func clamp(_ v: Double, _ lo: Double = -1, _ hi: Double = 1) -> Double { min(hi, max(lo, (v * 100).rounded() / 100)) }
        for filter in image.autoAdjustmentFilters(options: [.redEye: false]) {
            switch filter.name {
            case "CIVibrance":
                if let a = filter.value(forKey: "inputAmount") as? NSNumber { r.vibrance = clamp(a.doubleValue) }
            case "CIHighlightShadowAdjust":
                if let h = filter.value(forKey: "inputHighlightAmount") as? NSNumber { r.highlights = clamp((h.doubleValue - 1) * 1.5, -1, 0) }
                if let s = filter.value(forKey: "inputShadowAmount") as? NSNumber { r.shadows = clamp(s.doubleValue * 1.5, 0, 1) }
            case "CIToneCurve":
                var pts: [[Double]] = []
                for i in 0..<5 {
                    if let v = filter.value(forKey: "inputPoint\(i)") as? CIVector {
                        pts.append([clamp(Double(v.x), 0, 1), clamp(Double(v.y), 0, 1)])
                    }
                }
                pts.sort { $0[0] < $1[0] }
                var strictly: [[Double]] = []
                for p in pts where strictly.last.map({ p[0] > $0[0] }) ?? true { strictly.append(p) }
                if strictly.count >= 2 { r.curve = strictly }
            case "CIFaceBalance":
                // Skin-tone correction in YIQ: move I (orange–blue) and Q (purple–green) towards neutral skin.
                let i = (filter.value(forKey: "inputOrigI") as? NSNumber)?.doubleValue ?? 0
                let q = (filter.value(forKey: "inputOrigQ") as? NSNumber)?.doubleValue ?? 0
                let strength = (filter.value(forKey: "inputStrength") as? NSNumber)?.doubleValue ?? 0.5
                let skinI = 0.12
                r.warmth = clamp((skinI - i) * 2.5 * strength, -0.4, 0.4)
                r.tint = clamp(q * 2.5 * strength, -0.4, 0.4)
            default:
                break
            }
        }
        return r.normalized()
    }

    /// Edit versions increase across the whole library and are never reused (image URLs carry the
    /// version and are cached as immutable, also after a photo was purged and added again).
    static func nextVersion(_ d: Database) throws -> Int {
        let last = try Int.fetchOne(d, sql: "SELECT CAST(json_extract(value, '$') AS INTEGER) FROM setting WHERE key = 'lastEditVersion'") ?? 0
        let next = max(last, try Int.fetchOne(d, sql: "SELECT MAX(version) FROM edit") ?? 0) + 1
        try d.execute(sql: "INSERT INTO setting (key, value) VALUES ('lastEditVersion', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                      arguments: [String(next)])
        return next
    }

    // MARK: Relink / purge

    /// Content changed at the same path: the current edit follows the photo. A different pixel size
    /// keeps the adjustments but drops the geometry (crop coordinates would no longer fit).
    static func relink(_ d: Database, from oldId: String, to newId: String, sizeChanged: Bool) throws {
        guard let old = try Asset.fetchOne(d, key: oldId), old.editVersion > 0,
              var new = try Asset.fetchOne(d, key: newId), new.editVersion == 0,
              var r = try recipe(d, id: oldId, version: old.editVersion) else { return }
        if sizeChanged { r = r.withoutGeometry.normalized() }
        guard !r.isIdentity else { return }
        let v = try nextVersion(d)
        try d.execute(sql: "INSERT INTO edit (assetId, version, recipe, createdAt) VALUES (?, ?, ?, ?)",
                      arguments: [newId, v, try encode(r), Date()])
        new.editVersion = v
        try new.update(d)
    }
}
