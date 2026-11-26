import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import GRDB
@testable import PhotoCore

@Suite struct TextRecognitionTests {
    func image(text: String?) -> CGImage {
        let ctx = CGContext(data: nil, width: 1200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
        if let text {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 90, nil)
            let s = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font,
                                                                  .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            ctx.textPosition = CGPoint(x: 60, y: 160)
            CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        }
        return ctx.makeImage()!
    }

    @Test func readsText() throws {
        let t = try TextService.recognize(image(text: "Budapest Kitchen 1984"))
        #expect(t.contains("Budapest") && t.contains("1984"))
    }

    @Test func blankHasNoText() throws {
        #expect(try TextService.recognize(image(text: nil)) == "")
    }
}

@Suite struct DuplicateTests {
    /// Two different real photos of one trip (synthetic images look too alike to Vision).
    func photo(seed: Int) -> CGImage {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("demo/Library/Dolomites/\(seed == 1 ? "IMG_4170" : "IMG_4177").jpg")
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }

    func scaled(_ img: CGImage, by f: Double) -> CGImage {
        let w = Int(Double(img.width) * f), h = Int(Double(img.height) * f)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func insert(_ db: AppDatabase, _ id: String, _ img: CGImage, taken: Date, root: String = "library") throws {
        try db.writer.write { d in
            var a = Asset.placeholder(id: id)
            a.width = img.width; a.height = img.height; a.mime = "public.jpeg"; a.takenAt = taken
            try a.insert(d)
            let folder = try Int64.fetchOne(d, sql: "SELECT id FROM folder WHERE relPath = '' AND root = ?", arguments: [root]) ?? {
                var f = Folder(id: nil, relPath: "", parentId: nil, name: "", root: root)
                try f.insert(d)
                return f.id!
            }()
            var row = FileRow(id: nil, assetId: id, relPath: "\(id).jpg", folderId: folder, size: 100, mtime: 0, sidecarRelPath: nil, root: root)
            try row.insert(d)
        }
        try DuplicateService(db: db).store(assetId: id, dhash: DuplicateService.dhash(img), print: try DuplicateService.featurePrint(img))
    }

    let id = { (c: Character) in String(repeating: c, count: 64) }

    @Test func findsResizedCopiesNotOtherPhotos() throws {
        let db = try AppDatabase.inMemory()
        let a = photo(seed: 1)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        try insert(db, id("a"), a, taken: day)
        try insert(db, id("b"), scaled(a, by: 0.5), taken: day.addingTimeInterval(86400 * 300), root: "uploads")
        try insert(db, id("c"), photo(seed: 2), taken: day.addingTimeInterval(30))
        // a crop moments later is a different shot, not a duplicate
        try insert(db, id("d"), a.cropping(to: CGRect(x: 0, y: 0, width: a.width * 8 / 10, height: a.height * 8 / 10))!,
                   taken: day.addingTimeInterval(5))
        let s = DuplicateService(db: db)
        let groups = try s.groups()
        #expect(groups.count == 1)
        #expect(groups.first?.kind == "same")
        #expect(Set(groups.first?.items.map(\.id) ?? []) == [id("a"), id("b")])
        #expect(groups.first?.items.first { $0.id == id("b") }?.root == "uploads")

        // dismissed groups stay hidden
        try s.dismiss(key: groups[0].key)
        #expect(try s.groups().isEmpty)
    }

    @Test func mergeCarriesAlbumsAndFavourite() throws {
        let db = try AppDatabase.inMemory()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        try insert(db, id("a"), photo(seed: 1), taken: day)
        try insert(db, id("b"), photo(seed: 1), taken: day)
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO album (id, title, createdAt) VALUES (1, 'Trip', ?)", arguments: [day])
            try d.execute(sql: "INSERT INTO album_asset (albumId, assetId, position) VALUES (1, ?, 0)", arguments: [id("b")])
            try d.execute(sql: "UPDATE asset SET favorite = 1 WHERE id = ?", arguments: [id("b")])
        }
        try DuplicateService(db: db).merge(keep: id("a"), others: [id("b")])
        let (albums, fav) = try db.writer.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM album_asset WHERE assetId = ?", arguments: [id("a")]),
             try Bool.fetchOne(d, sql: "SELECT favorite FROM asset WHERE id = ?", arguments: [id("a")]))
        }
        #expect(albums == 1 && fav == true)
    }
}

@Suite struct AnalysisCountTests {
    @Test func countsPendingAndTotalSkippingMissing() throws {
        let db = try AppDatabase.inMemory()
        let ids = ["a", "b", "c"].map { String(repeating: $0, count: 64) }
        try db.writer.write { d in
            for id in ids { try Asset.placeholder(id: id).insert(d) }
            try d.execute(sql: "UPDATE asset SET textVersion = ?, printVersion = ? WHERE id = ?",
                          arguments: [TextService.version, DuplicateService.version, ids[0]])
            try d.execute(sql: "UPDATE asset SET missingSince = ? WHERE id = ?", arguments: [Date(), ids[2]])
        }
        let c = try JobRunner.analysisCounts(db)
        #expect(c.total == 2)
        #expect(c.pending == 1)
    }
}
