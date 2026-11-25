import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PhotoCore

/// Editing HDR (gain-map) photos: the edit pipeline's HDR rendition and the gain maps of saved edits.
@Suite struct HDREditTests {
    typealias H = HDRDerivativeTests

    /// A gain-map original (bright top-left quadrant) and a service-free way to render + store an edit.
    func setup(orientation: Int = 1) throws -> (src: URL, store: DerivativeStore) {
        let dir = Fixtures.tempDir()
        let src = dir.appendingPathComponent("hdr.heic")
        try H.writeHDR(to: src, orientation: orientation)
        return (src, DerivativeStore(cacheDir: dir.appendingPathComponent("cache")))
    }

    func saveEdit(_ recipe: EditRecipe, src: URL, store: DerivativeStore) throws -> URL {
        let service = EditService(db: try AppDatabase.inMemory(), catalog: CatalogService(db: try AppDatabase.inMemory(), settings: SettingsStore(db: try AppDatabase.inMemory())),
                                  derivatives: { store })
        let (image, hdr) = try service.renderPreview(id: "abcdef", source: src, recipe: recipe)
        try store.storeEdited(image, hdr: hdr, id: "abcdef", version: 1, format: .heic)
        return store.url(id: "abcdef", kind: .preview, editVersion: 1, format: .heic)
    }

    @Test func normalizedGainMapReproducesTheOriginalsHDR() throws {
        let (src, _) = try setup()
        let map = try #require(try NormalizedGainMap.make(source: src, maxPixel: 256))
        #expect(max(map.width, map.height) == 256 && map.stops > 1)
        // SDR × 2^(map × stops) ≈ the original decoded in HDR, at each quadrant's centre.
        let sdr = try H.quadrants(src, hdr: false), hdr = try H.quadrants(src, hdr: true)
        let centres = [(1, 1), (3, 1), (1, 3), (3, 3)].map { map.pixels[($0.1 * map.height / 4) * map.width + $0.0 * map.width / 4] }
        for i in 0..<4 {
            // (quadrants() returns linear light)
            let rebuilt = sdr[i] * exp2(Float(centres[i]) / 255 * map.stops), want = hdr[i]
            #expect(abs(rebuilt - want) / want < 0.12, "quadrant \(i): rebuilt \(rebuilt) vs \(want)")
        }
        #expect(try NormalizedGainMap.decode(map.encoded()) == map)
    }

    @Test func sdrPhotoHasNoGainMap() throws {
        let dir = Fixtures.tempDir()
        let src = dir.appendingPathComponent("src.jpg")
        Fixtures.writeJPEG(to: src)
        #expect(try NormalizedGainMap.make(source: src, maxPixel: 256) == nil)
        let store = DerivativeStore(cacheDir: dir.appendingPathComponent("cache"))
        #expect(try store.ensureGainMap(id: "abcdef", source: src) == nil)
        #expect(try store.ensureGainMap(id: "abcdef", source: src) == nil)  // remembered
        var r = EditRecipe(); r.exposure = 0.5
        #expect(H.gainMapTypes(try saveEdit(r, src: src, store: store)).isEmpty)
    }

    @Test func hdrRenditionLiftsHighlightsAndSdrRenditionIsUnchanged() throws {
        let (src, _) = try setup()
        let map = try #require(try NormalizedGainMap.make(source: src, maxPixel: 512))
        let base = try DerivativeStore.downscaled(source: src, maxPixel: 600)
        let renderer = try EditRenderer.shared()
        var r = EditRecipe(); r.contrast = 0.3
        let plain = try renderer.render(rgba: try EditRenderer.rgba(of: base), width: base.width, height: base.height, recipe: r)
        let both = try renderer.render(rgba: try EditRenderer.rgba(of: base), width: base.width, height: base.height, recipe: r, gainMap: map)
        #expect(both.sdr == plain.pixels, "SDR rendition is the plain render")
        let hdr = try #require(both.hdr)
        func value(_ x: Int, _ y: Int) -> Float { Float(Float16(bitPattern: hdr[(y * both.width + x) * 4 + 1])) }
        #expect(value(both.width / 4, both.height / 4) > 1.4, "highlight above SDR white: \(value(both.width / 4, both.height / 4))")
        #expect(value(3 * both.width / 4, 3 * both.height / 4) < 0.7)
        let cap = 1.055 * pow(map.headroom, 1 / 2.4) - 0.055  // the headroom, encoded like the output
        #expect(value(both.width / 4, both.height / 4) <= cap + 0.01, "never above the photo's headroom")
    }

    @Test func tonalEditKeepsHDR() throws {
        let (src, store) = try setup()
        var r = EditRecipe(); r.exposure = -0.5; r.saturation = 0.2
        let preview = try saveEdit(r, src: src, store: store)
        #expect(!H.gainMapTypes(preview).isEmpty)
        let q = try H.quadrants(preview, hdr: true), sdr = try H.quadrants(preview, hdr: false)
        #expect(q[0] > sdr[0] * 1.8, "highlights brighter than SDR: \(q) vs \(sdr)")
        #expect(q[0] / sdr[0] > 1.3 * (q[3] / sdr[3]), "highlights gain more than shadows")
        let thumb = store.url(id: "abcdef", kind: .thumb, editVersion: 1, format: .heic)
        #expect(try H.quadrants(thumb, hdr: true)[0] > 1.5)
    }

    @Test func geometryOnlyEditCarriesTheOriginalGainMap() throws {
        let (src, store) = try setup(orientation: 6)
        var r = EditRecipe(); r.rotate = 1; r.flipH = true
        let preview = try saveEdit(r, src: src, store: store)
        #expect(H.gainMapTypes(preview) == H.gainMapTypes(src), "same gain-map format as the original")
        let orig = try H.quadrants(src, hdr: true)
        // Expected placement: rotate the original's (oriented) quadrants clockwise, then mirror.
        // Quadrants: 0 TL, 1 TR, 2 BL, 3 BR. Clockwise: TL→TR, TR→BR, BR→BL, BL→TL; mirror swaps L/R.
        let cw = [1, 3, 0, 2], mirror = [1, 0, 3, 2]
        let bright = orig.firstIndex(of: orig.max()!)!
        let q = try H.quadrants(preview, hdr: true)
        #expect(q.firstIndex(of: q.max()!) == mirror[cw[bright]] && q.max()! > 2, "\(orig) → \(q)")
        // The SDR pixels follow the same geometry.
        let s = try H.quadrants(preview, hdr: false)
        #expect(s.firstIndex(of: s.max()!) == mirror[cw[bright]])
    }
}
