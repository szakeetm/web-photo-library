import Testing
import Foundation
import CryptoKit
@testable import PhotoCore

/// The edit pipeline's reference outputs. The web app's tests compare its WebGPU renders against the
/// same files, so preview (browser) and export (server) match by construction.
/// Regenerate after an intended shader change: UPDATE_GOLDENS=1 scripts/test-server.sh --filter EditRender
@Suite struct EditRenderTests {
    static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../shaders").standardizedFileURL
    static let tolerance = 1  // per channel, of 255

    @Test func generatedMetalIsCurrent() throws {
        let wgsl = try Data(contentsOf: Self.shaders.appendingPathComponent("edit.wgsl"))
        let hash = SHA256.hash(data: wgsl).map { String(format: "%02x", $0) }.joined()
        #expect(hash == editShaderSourceHash, "shaders/edit.wgsl changed: run scripts/gen-shaders.sh")
    }

    @Test func rendersMatchGoldens() throws {
        let renderer = try EditRenderer.shared()
        let fixtures = Self.shaders.appendingPathComponent("fixtures")
        let src = [UInt8](try Data(contentsOf: fixtures.appendingPathComponent("fixture-96x64.rgba")))
        let recipes = try JSONDecoder().decode([String: EditRecipe].self, from: Data(contentsOf: fixtures.appendingPathComponent("recipes.json")))
        let update = ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1"
        var manifest: [String: [Int]] = [:]
        for (name, recipe) in recipes.sorted(by: { $0.key < $1.key }) {
            let out = try renderer.render(rgba: src, width: 96, height: 64, recipe: try recipe.validated())
            let golden = fixtures.appendingPathComponent("golden/\(name).rgba")
            manifest[name] = [out.width, out.height]
            if update {
                try Data(out.pixels).write(to: golden)
                continue
            }
            let expected = [UInt8](try Data(contentsOf: golden))
            #expect(expected.count == out.pixels.count, "\(name): size")
            guard expected.count == out.pixels.count else { continue }
            let maxDiff = zip(expected, out.pixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(maxDiff <= Self.tolerance, "\(name): max channel difference \(maxDiff)")
        }
        if update {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            try enc.encode(manifest).write(to: fixtures.appendingPathComponent("golden/sizes.json"))
        }
    }

    /// HDR rendition references: the fixture plus a gain map (horizontal ramp 0…255 over the top three
    /// quarters, none below) of `hdrStops` stops. Files hold RGBA half floats (little-endian).
    static let hdrRecipes = ["identity", "exposure", "light", "everything"]
    static let hdrStops: Float = 2

    @Test func hdrRendersMatchGoldens() throws {
        let renderer = try EditRenderer.shared()
        let fixtures = Self.shaders.appendingPathComponent("fixtures")
        let src = [UInt8](try Data(contentsOf: fixtures.appendingPathComponent("fixture-96x64.rgba")))
        let gain = NormalizedGainMap(pixels: [UInt8](try Data(contentsOf: fixtures.appendingPathComponent("gain-96x64.r8"))),
                                     width: 96, height: 64, stops: Self.hdrStops)
        let recipes = try JSONDecoder().decode([String: EditRecipe].self, from: Data(contentsOf: fixtures.appendingPathComponent("recipes.json")))
        let update = ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1"
        for name in Self.hdrRecipes {
            let recipe = try #require(recipes[name])
            let out = try renderer.render(rgba: src, width: 96, height: 64, recipe: try recipe.validated(), gainMap: gain)
            let hdr = try #require(out.hdr)
            let golden = fixtures.appendingPathComponent("golden/hdr-\(name).rgba16f")
            let bytes = hdr.withUnsafeBytes { Data($0) }
            if update { try bytes.write(to: golden); continue }
            let expected = try Data(contentsOf: golden).withUnsafeBytes { [UInt16]($0.bindMemory(to: UInt16.self)) }
            #expect(expected.count == hdr.count, "\(name): size")
            guard expected.count == hdr.count else { continue }
            let maxDiff = zip(expected, hdr).map { abs(Float(Float16(bitPattern: $0)) - Float(Float16(bitPattern: $1))) }.max() ?? 0
            #expect(maxDiff <= 0.01, "\(name): max difference \(maxDiff)")
            // The ramp reaches above SDR white; the SDR rendition is unchanged by the gain map.
            #expect(hdr.contains { Float(Float16(bitPattern: $0)) > 1.2 }, "\(name): has HDR highlights")
            #expect(out.sdr == (try renderer.render(rgba: src, width: 96, height: 64, recipe: try recipe.validated())).pixels)
        }
    }

    @Test func identityKeepsPixels() throws {
        let renderer = try EditRenderer.shared()
        let src = [UInt8](try Data(contentsOf: Self.shaders.appendingPathComponent("fixtures/fixture-96x64.rgba")))
        let out = try renderer.render(rgba: src, width: 96, height: 64, recipe: EditRecipe())
        let maxDiff = zip(src, out.pixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(out.width == 96 && out.height == 64 && maxDiff <= 1)
    }

    @Test func geometryOutputSizes() {
        var r = EditRecipe()
        r.rotate = 1
        #expect(r.outputSize(sourceWidth: 400, sourceHeight: 300) == (300, 400))
        r.crop = .init(x: 0, y: 0, w: 0.5, h: 0.25)
        #expect(r.outputSize(sourceWidth: 400, sourceHeight: 300) == (150, 100))
        #expect(EditRecipe.lumaSize(sourceWidth: 4000, sourceHeight: 3000) == (256, 192))
    }

    @Test func validationRejectsOutOfRange() throws {
        var r = EditRecipe()
        r.exposure = 5
        #expect(throws: EditRecipe.Invalid.self) { try r.validated() }
        r = EditRecipe(); r.schema = 99
        #expect(throws: EditRecipe.Invalid.self) { try r.validated() }
        r = EditRecipe(); r.curve = [[0.5, 0], [0.2, 1]]
        #expect(throws: EditRecipe.Invalid.self) { try r.validated() }
        r = EditRecipe(); r.crop = .init(x: 0.5, y: 0, w: 0.6, h: 1)
        #expect(throws: EditRecipe.Invalid.self) { try r.validated() }
        r = EditRecipe(); r.exposure = 0; r.rotate = 0; r.curve = [[0, 0], [1, 1]]
        #expect(r.isIdentity && r.normalized() == EditRecipe())
    }
}
