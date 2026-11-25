import Foundation

/// A non-destructive edit. Every field is optional; a missing field means "unchanged".
/// Versioned by `schema`: the server only accepts its current schema and upgrades stored recipes.
public struct EditRecipe: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public struct Crop: Codable, Sendable, Equatable {
        public var x: Double, y: Double, w: Double, h: Double
        public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
        public static let full = Crop(x: 0, y: 0, w: 1, h: 1)
    }

    public var schema: Int = currentSchema
    // geometry
    public var crop: Crop?
    public var straighten: Double?   // degrees, -45…45
    public var rotate: Int?          // clockwise quarter turns, 0…3
    public var flipH: Bool?
    public var flipV: Bool?
    // light
    public var exposure: Double?     // EV, -3…3
    public var brilliance: Double?
    public var highlights: Double?
    public var shadows: Double?
    public var brightness: Double?
    public var contrast: Double?
    public var blackPoint: Double?
    // colour
    public var saturation: Double?
    public var vibrance: Double?
    public var warmth: Double?
    public var tint: Double?
    // tone curve: [[x, y], …], x ascending, 0…1, 2…16 points
    public var curve: [[Double]]?
    // effects
    public var vignette: Double?
    public var sharpen: Double?      // 0…1

    public init() {}

    public enum Invalid: Error, CustomStringConvertible {
        case schema(Int), value(String)
        public var description: String {
            switch self {
            case .schema(let s): "Edit format \(s) is not supported by this server (expects \(EditRecipe.currentSchema))."
            case .value(let f): "Invalid edit value: \(f)"
            }
        }
    }

    /// Rejects values outside their ranges (a client bug), so a stored recipe always renders.
    public func validated() throws -> EditRecipe {
        guard schema == Self.currentSchema else { throw Invalid.schema(schema) }
        func check(_ v: Double?, _ name: String, _ lo: Double = -1, _ hi: Double = 1) throws {
            if let v, !(v.isFinite && v >= lo && v <= hi) { throw Invalid.value(name) }
        }
        try check(exposure, "exposure", -3, 3)
        for (v, n) in [(brilliance, "brilliance"), (highlights, "highlights"), (shadows, "shadows"), (brightness, "brightness"),
                       (contrast, "contrast"), (blackPoint, "blackPoint"), (saturation, "saturation"), (vibrance, "vibrance"),
                       (warmth, "warmth"), (tint, "tint"), (vignette, "vignette")] {
            try check(v, n)
        }
        try check(sharpen, "sharpen", 0, 1)
        try check(straighten, "straighten", -45, 45)
        if let r = rotate, !(0...3).contains(r) { throw Invalid.value("rotate") }
        if let c = crop {
            let ok = [c.x, c.y, c.w, c.h].allSatisfy(\.isFinite) && c.x >= -1e-6 && c.y >= -1e-6 && c.w > 0.001 && c.h > 0.001
                && c.x + c.w <= 1 + 1e-6 && c.y + c.h <= 1 + 1e-6
            if !ok { throw Invalid.value("crop") }
        }
        if let pts = curve {
            guard (2...16).contains(pts.count), pts.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } }),
                  zip(pts, pts.dropFirst()).allSatisfy({ $0[0] < $1[0] }) else { throw Invalid.value("curve") }
        }
        return self
    }

    /// Recipe with no visible effect (all defaults).
    public var isIdentity: Bool { normalized() == EditRecipe() }

    /// Drops values equal to their defaults, so equal edits compare (and store) equal.
    public func normalized() -> EditRecipe {
        var r = self
        func z(_ v: inout Double?) { if v == 0 { v = nil } }
        z(&r.straighten); z(&r.exposure); z(&r.brilliance); z(&r.highlights); z(&r.shadows); z(&r.brightness)
        z(&r.contrast); z(&r.blackPoint); z(&r.saturation); z(&r.vibrance); z(&r.warmth); z(&r.tint)
        z(&r.vignette); z(&r.sharpen)
        if r.rotate == 0 { r.rotate = nil }
        if r.flipH == false { r.flipH = nil }
        if r.flipV == false { r.flipV = nil }
        if r.crop == .full { r.crop = nil }
        if let c = r.curve, c == [[0, 0], [1, 1]] { r.curve = nil }
        return r
    }

    /// The same edit without crop/straighten/rotate/flip (used when the photo's pixel size changed).
    public var withoutGeometry: EditRecipe {
        var r = self
        r.crop = nil; r.straighten = nil; r.rotate = nil; r.flipH = nil; r.flipV = nil
        return r
    }

    // MARK: Shader parameters (layout documented in shaders/edit.wgsl)

    /// Output pixel size for a source of the given (oriented) size.
    public func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let odd = ((rotate ?? 0) & 1) == 1
        let fw = Double(odd ? sourceHeight : sourceWidth), fh = Double(odd ? sourceWidth : sourceHeight)
        let c = crop ?? .full
        return (max(1, Int((c.w * fw).rounded())), max(1, Int((c.h * fh).rounded())))
    }

    public static func lumaSize(sourceWidth w: Int, sourceHeight h: Int) -> (width: Int, height: Int) {
        let long = 256.0
        if w >= h { return (256, max(1, Int((long * Double(h) / Double(w)).rounded()))) }
        return (max(1, Int((long * Double(w) / Double(h)).rounded())), 256)
    }

    /// 16 × vec4<f32> uniform block.
    public func shaderParams(outW: Int, outH: Int, srcW: Int, srcH: Int, blur: (Float, Float) = (0, 0)) -> [Float] {
        var v = [Float](repeating: 0, count: 64)
        func set(_ i: Int, _ a: Double, _ b: Double, _ c: Double, _ d: Double) {
            v[i * 4] = Float(a); v[i * 4 + 1] = Float(b); v[i * 4 + 2] = Float(c); v[i * 4 + 3] = Float(d)
        }
        let c = crop ?? .full
        let luma = Self.lumaSize(sourceWidth: srcW, sourceHeight: srcH)
        let pts = (curve?.count ?? 0) >= 2 ? curve! : []
        set(0, Double(outW), Double(outH), Double(srcW), Double(srcH))
        set(1, c.x, c.y, c.w, c.h)
        set(2, straighten ?? 0, Double(rotate ?? 0), (flipH ?? false) ? 1 : 0, (flipV ?? false) ? 1 : 0)
        set(3, exposure ?? 0, brilliance ?? 0, highlights ?? 0, shadows ?? 0)
        set(4, brightness ?? 0, contrast ?? 0, blackPoint ?? 0, saturation ?? 0)
        set(5, vibrance ?? 0, warmth ?? 0, tint ?? 0, vignette ?? 0)
        set(6, sharpen ?? 0, Double(pts.count), 0, 0)
        set(7, Double(blur.0), Double(blur.1), Double(luma.width), Double(luma.height))
        for (i, p) in pts.prefix(16).enumerated() {
            v[32 + i * 2] = Float(p[0]); v[32 + i * 2 + 1] = Float(p[1])
        }
        return v
    }
}
