import Testing
import Foundation
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import ImageIO
@testable import PhotoAPI
@testable import PhotoCore

@Suite struct EditAPITests {
    let base = APITests()

    func body(_ s: String) -> ByteBuffer { ByteBuffer(string: s) }

    @Test func saveRenderHistoryRevert() async throws {
        let e = try base.env()
        let id = base.indexed(e)
        let snap = try e.services.catalog.catalog()
        try await e.app.test(.router) { client in
            // save: renders edited derivatives, bumps the edit version, appears in the change feed
            try await client.execute(uri: "/api/assets/\(id)/edits", method: .post,
                                     body: body(#"{"recipe":{"schema":1,"exposure":0.5,"crop":{"x":0,"y":0,"w":0.5,"h":1}}}"#)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"ev\":1"))
            }
            let store = e.services.derivatives()
            for f in ImageFormat.allCases {
                #expect(store.exists(id: id, kind: .preview, editVersion: 1, format: f))
                #expect(store.exists(id: id, kind: .thumb, editVersion: 1, format: f))
            }
            // the edited preview has the cropped aspect (640×480 source, half width → 320×480 → ≤2048 kept)
            let prev = store.url(id: id, kind: .preview, editVersion: 1, format: .jpeg)
            let src = CGImageSourceCreateWithURL(prev as CFURL, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
            #expect(props[kCGImagePropertyPixelWidth] as? Int == 320 && props[kCGImagePropertyPixelHeight] as? Int == 480)
            let delta = try e.services.catalog.changes(since: snap.seq, catalogId: snap.catalogId)
            #expect(delta.assets.first?.ev == 1)

            // second version, history
            try await client.execute(uri: "/api/assets/\(id)/edits", method: .post, body: body(#"{"recipe":{"schema":1,"warmth":0.4}}"#)) { res in
                #expect(String(buffer: res.body).contains("\"ev\":2"))
            }
            try await client.execute(uri: "/api/assets/\(id)/edits", method: .get) { res in
                let h = try JSONDecoder.iso.decode(EditHistory.self, from: Data(buffer: res.body))
                #expect(h.current == 2 && h.versions.map(\.version) == [1, 2] && h.versions[1].recipe.warmth == 0.4)
            }
            // revert keeps history; an identity save also reverts
            try await client.execute(uri: "/api/assets/\(id)/revert", method: .post) { res in
                #expect(String(buffer: res.body).contains("\"ev\":0"))
            }
            try await client.execute(uri: "/api/assets/\(id)/edits", method: .post, body: body(#"{"recipe":{"schema":1,"exposure":0}}"#)) { res in
                #expect(String(buffer: res.body).contains("\"ev\":0"))
            }
            #expect(try e.services.edits.history(id: id)?.versions.count == 2)
        }
    }

    @Test func olderSaveNeverReplacesNewerAndVersionsAreNotReused() throws {
        let e = try base.env()
        let id = base.indexed(e)
        var r = EditRecipe(); r.exposure = 1
        let a = try e.services.edits.save(id: id, recipe: r)
        r.exposure = 2
        let b = try e.services.edits.save(id: id, recipe: r)
        #expect(b.ev > a.ev)
        try e.services.db.writer.write { d in
            // a late finish of the older save
            try d.execute(sql: "UPDATE asset SET editVersion = ? WHERE id = ? AND (? = 0 OR editVersion < ?)", arguments: [a.ev, id, a.ev, a.ev])
            try d.execute(sql: "DELETE FROM edit")
        }
        #expect(try e.services.edits.history(id: id)?.current == b.ev)
        let c = try e.services.edits.save(id: id, recipe: r)
        #expect(c.ev > b.ev)  // not reused after the rows were deleted
    }

    @Test func negativeEditVersionIsRefused() async throws {
        let e = try base.env()
        let id = base.indexed(e)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/preview/\(id)?e=-1&fmt=jpeg", method: .get) { res in #expect(res.status == .notFound) }
        }
    }

    @Test func invalidAndOutdatedRecipes() async throws {
        let e = try base.env()
        let id = base.indexed(e)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/assets/\(id)/edits", method: .post, body: body(#"{"recipe":{"schema":1,"exposure":9}}"#)) { res in
                #expect(res.status == .badRequest)
            }
            try await client.execute(uri: "/api/assets/\(id)/edits", method: .post, body: body(#"{"recipe":{"schema":2}}"#)) { res in
                #expect(res.status == .conflict && String(buffer: res.body).contains("updateRequired"))
            }
            try await client.execute(uri: "/api/assets/\(id)/edits", method: .post, body: body("nonsense")) { res in
                #expect(res.status == .badRequest)
            }
            try await client.execute(uri: "/api/assets/\(String(repeating: "a", count: 64))/edits", method: .post,
                                     body: body(#"{"recipe":{"schema":1,"exposure":1}}"#)) { res in
                #expect(res.status == .conflict || res.status == .notFound)
            }
        }
    }

    @Test func editedDerivativesComeBackAfterCacheClear() async throws {
        let e = try base.env()
        let id = base.indexed(e)
        _ = try e.services.edits.save(id: id, recipe: { var r = EditRecipe(); r.saturation = -1; return r }())
        try e.services.derivatives().clear()
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/preview/\(id)?e=1&fmt=jpeg", method: .get) { res in
                #expect(res.status == .ok && res.headers[.contentType] == "image/jpeg")
            }
            try await client.execute(uri: "/api/thumb/\(id)?e=7&fmt=jpeg", method: .get) { res in
                #expect(res.status == .notFound)
            }
        }
        // rebuild caches renders the current edit (and its BlurHash) again
        try e.services.derivatives().clear()
        e.services.jobs.enqueue(.rebuildCaches)
        e.services.jobs.waitUntilIdle()
        #expect(e.services.derivatives().exists(id: id, kind: .thumb, editVersion: 1, format: .heic))
    }

    @Test func exportFullResolutionWithMetadata() async throws {
        let e = try base.env()
        let id = base.indexed(e)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/assets/\(id)/export?fmt=jpeg", method: .get) { res in
                #expect(res.status == .notFound)  // nothing to export before an edit
            }
            _ = try e.services.edits.save(id: id, recipe: { var r = EditRecipe(); r.rotate = 1; return r }())
            try await client.execute(uri: "/api/assets/\(id)/export?fmt=jpeg", method: .get) { res in
                #expect(res.status == .ok)
                #expect(res.headers[.contentDisposition]?.contains("IMG%201-edited.jpg") == true)
                let data = Data(buffer: res.body)
                let src = CGImageSourceCreateWithData(data as CFData, nil)!
                let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
                #expect(p[kCGImagePropertyPixelWidth] as? Int == 480 && p[kCGImagePropertyPixelHeight] as? Int == 640)
                #expect((p[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
            }
        }
    }

    @Test func autoEnhanceReturnsUnsavedRecipe() async throws {
        let e = try base.env()
        let id = base.indexed(e)
        try await e.app.test(.router) { client in
            try await client.execute(uri: "/api/assets/\(id)/auto-enhance", method: .post) { res in
                #expect(res.status == .ok && String(buffer: res.body).contains("\"schema\":1"))
            }
        }
        #expect(try e.services.edits.history(id: id)?.current == 0)
    }

    @Test func editFollowsChangedContentAndPurgeRemovesIt() async throws {
        let e = try base.env()
        let id = base.indexed(e)
        _ = try e.services.edits.save(id: id, recipe: { var r = EditRecipe(); r.exposure = 1; r.crop = .init(x: 0, y: 0, w: 0.5, h: 0.5); return r }())
        // rewrite the file in place with a different size: same path, new content
        let file = e.root.appendingPathComponent("Trip/IMG 1.jpg")
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        e.services.jobs.enqueue(.detectChanges)
        e.services.jobs.waitUntilIdle()
        let newId = try #require(e.services.catalog.catalog().assets.first?.id)
        #expect(newId != id)
        let h = try #require(try e.services.edits.history(id: newId))
        #expect(h.versions.count == 1 && h.current == h.versions[0].version && h.current > 1)
        #expect(h.versions[0].recipe.exposure == 1 && h.versions[0].recipe.crop == nil)
        e.services.jobs.enqueue(.purgeMissing)
        e.services.jobs.waitUntilIdle()
        #expect(try e.services.edits.recipe(id: id, version: 1) == nil)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
