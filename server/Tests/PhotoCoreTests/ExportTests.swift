import Testing
import Foundation
import CoreGraphics
import ImageIO
import GRDB
@testable import PhotoCore

@Suite struct ZipStreamTests {
    func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func writesAnArchiveUnzipAndDittoRead() async throws {
        let dir = Fixtures.tempDir()
        let big = dir.appendingPathComponent("big.bin")
        var bytes = Data(count: 3 * ZipStream.chunk + 123)
        for i in stride(from: 0, to: bytes.count, by: 97) { bytes[i] = UInt8(i % 251) }
        try bytes.write(to: big)
        let zipURL = dir.appendingPathComponent("out.zip")
        FileManager.default.createFile(atPath: zipURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: zipURL)
        let zip = ZipStream { handle.write($0) }
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try await zip.add(path: "2020/2020-09/big.bin", file: big, modified: date)
        try await zip.add(path: "Ünïcode name.json", data: Data("{\"a\":1}".utf8), modified: date)
        try await zip.add(path: "empty.txt", data: Data(), modified: date)
        try await zip.finish()
        try handle.close()

        let (status, output) = try run("/usr/bin/unzip", ["-t", zipURL.path])
        #expect(status == 0, "\(output)")
        let outDir = dir.appendingPathComponent("x")
        let (dstatus, doutput) = try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, outDir.path])
        #expect(dstatus == 0, "\(doutput)")
        #expect(try Data(contentsOf: outDir.appendingPathComponent("2020/2020-09/big.bin")) == bytes)
        #expect(try String(contentsOf: outDir.appendingPathComponent("Ünïcode name.json"), encoding: .utf8) == "{\"a\":1}")
    }
}

@Suite struct ExportMetadataTests {
    func pixels(_ url: URL) throws -> Data {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        return try #require(img.dataProvider?.data) as Data
    }

    @Test func rewritesTheDateWithoutReencoding() throws {
        let dir = Fixtures.tempDir()
        let src = dir.appendingPathComponent("a.jpg")
        Fixtures.writeJPEG(to: src, dateTimeOriginal: "2021:07:04 15:30:00", offset: "+02:00")
        let out = dir.appendingPathComponent("b.jpg")
        let date = ISO8601DateFormatter().date(from: "2019-01-02T03:04:05Z")!
        #expect(MetadataRewriter.rewrite(source: src, to: out, takenAt: date, tzOffset: -5 * 3600))
        #expect(try pixels(src) == pixels(out))
        let p = try #require(ImageProbe.probe(url: out))
        #expect(p.exifDate == date && p.exifOffset == -5 * 3600)
    }

    @Test func googleSidecarRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let info = ExportInfo(title: "IMG_1.jpg", takenAt: date, tzOffset: 3600, lat: 47.5, lon: 19.04, description: "Danube",
                              favorite: true, people: [(name: "Anna", x: 0.1, y: 0.2, w: 0.3, h: 0.4)], albums: ["Trip"],
                              width: 100, height: 80)
        let parsed = try #require(SidecarParser.parse(SidecarWriter.google(info)))
        #expect(parsed.takenAt == date && parsed.lat == 47.5 && parsed.lon == 19.04)
        #expect(parsed.description == "Danube" && parsed.favorited == true)
        let xmp = String(decoding: SidecarWriter.xmp(info), as: UTF8.self)
        #expect(xmp.contains("exif:DateTimeOriginal=\"2020-09-13T13:26:40+01:00\""))
        #expect(xmp.contains("mwg-rs:Name=\"Anna\"") && xmp.contains("<rdf:li>Trip</rdf:li>") && xmp.contains("xmp:Rating=\"5\""))
        // well-formed XML
        #expect(XMLParser(data: SidecarWriter.xmp(info)).parse())
    }
}

@Suite struct ExportPlanTests {
    func setup() throws -> (AppDatabase, ExportService, [String: String]) {
        let root = Fixtures.tempDir()
        Fixtures.writeJPEG(to: root.appendingPathComponent("A/a.jpg"), dateTimeOriginal: "2021:07:04 15:30:00", offset: "+02:00", color: (1, 0, 0))
        Fixtures.writeJPEG(to: root.appendingPathComponent("B/a.jpg"), dateTimeOriginal: "2021:08:01 10:00:00", offset: "+02:00", color: (0, 1, 0))
        Fixtures.writeJPEG(to: root.appendingPathComponent("B/b.png"), dateTimeOriginal: "2021:08:02 10:00:00", offset: "+02:00", color: (0, 0, 1),
                           type: .png)
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, root.path)
        let s = LibraryScanner(db: db, root: root, serverTZ: TimeZone(identifier: "UTC")!) { try FileHasher.sha256(url: $0) }
        _ = try s.detectChanges(progress: { _, _ in }, isCancelled: { false })
        var ids: [String: String] = [:]
        for r in try db.writer.read({ try Row.fetchAll($0, sql: "SELECT assetId, relPath FROM file") }) { ids[r["relPath"]] = r["assetId"] }
        let catalog = CatalogService(db: db, settings: settings)
        let cache = Fixtures.tempDir()
        let edits = EditService(db: db, catalog: catalog, derivatives: { DerivativeStore(cacheDir: cache) })
        return (db, ExportService(db: db, catalog: catalog, edits: edits, ffmpeg: nil, cacheDir: cache), ids)
    }

    @Test func bothWithXMPByMonth() throws {
        let (db, ex, ids) = try setup()
        try MetadataService(db: db).change(ids: [ids["A/a.jpg"]!], DateChange(shift: 86400 * 40))  // → August
        var o = ExportOptions()
        o.library = true
        o.content = .both
        o.sidecar = .xmp
        o.organize = .months
        let paths = try ex.plan(o).map(\.path)
        // library order (by date): B/a.jpg (1 Aug), B/b.png (2 Aug), then A/a.jpg moved to 13 Aug
        #expect(paths == [
            "2021/2021-08/a.jpg", "2021/2021-08/a.xmp",
            "2021/2021-08/b.png", "2021/2021-08/b.xmp",
            "2021/2021-08/a (2).jpg", "2021/2021-08/a (2).xmp", "Originals/2021/2021-08/a (2).jpg",
        ], "\(paths)")
        // the date-adjusted one has its original under Originals/, with the same name
        #expect(paths.filter { $0.hasPrefix("Originals/") }.count == 1)
        #expect(Set(paths.filter { !$0.hasPrefix("Originals/") && $0.hasSuffix(".jpg") }) == ["2021/2021-08/a.jpg", "2021/2021-08/a (2).jpg"])
    }

    @Test func editedDateIsWrittenIntoTheCopy() async throws {
        let (db, ex, ids) = try setup()
        let id = ids["B/b.png"]!
        try MetadataService(db: db).change(ids: [id], DateChange(shift: -3600))
        let f = try #require(try await ex.editedFile(id: id, format: .jpeg))
        let p = try #require(ImageProbe.probe(url: f.url))
        #expect(p.exifLocalDate?.hour == 9 && f.name == "b.png")
        let srcURL = try #require(try ex.catalog.sourceURL(id: id))
        #expect(try ExportMetadataTests().pixels(srcURL) == ExportMetadataTests().pixels(f.url))
        // an unedited photo has no edited file
        #expect(try await ex.editedFile(id: ids["A/a.jpg"]!, format: .jpeg) == nil)
    }

    @Test func googleSidecarsAndAlbumsFolders() throws {
        let (db, ex, ids) = try setup()
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO album (id, title, createdAt) VALUES (1, 'Summer: Lake/Trip', ?)", arguments: [Date()])
            try d.execute(sql: "INSERT INTO album_asset (albumId, assetId, position) VALUES (1, ?, 0), (1, ?, 1)",
                          arguments: [ids["B/b.png"]!, ids["A/a.jpg"]!])
        }
        var o = ExportOptions()
        o.albums = [1]
        o.organize = .albums
        o.sidecar = .google
        o.content = .original
        let paths = try ex.plan(o).map(\.path)
        #expect(paths == ["Summer- Lake-Trip/a.jpg", "Summer- Lake-Trip/a.jpg.supplemental-metadata.json",
                          "Summer- Lake-Trip/b.png", "Summer- Lake-Trip/b.png.supplemental-metadata.json"], "\(paths)")
    }
}

@Suite struct ExportRunTests {
    func library() throws -> (ExportService, [ExportEntry], URL) {
        let (db, ex, _) = try ExportPlanTests().setup()
        var o = ExportOptions()
        o.library = true
        let entries = try ex.plan(o)
        let root = try #require(try SettingsStore(db: db).get(.libraryPath)).map { URL(fileURLWithPath: $0) }!
        return (ex, entries, root)
    }

    @Test func summaryCountsItemsAndBytes() throws {
        let (_, entries, root) = try library()
        let s = ExportSummary(entries)
        #expect(s.files == 3 && s.items == 3)
        let disk = try ["A/a.jpg", "B/a.jpg", "B/b.png"].reduce(Int64(0)) {
            $0 + ((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent($1).path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        #expect(s.bytes == disk)
    }

    @Test func aMissingFileIsSkippedAndListed() async throws {
        let (ex, entries, root) = try library()
        try FileManager.default.removeItem(at: root.appendingPathComponent("B/b.png"))
        let out = Fixtures.tempDir()
        var skipped: [String] = []
        try await ex.run(entries, format: .jpeg, write: ExportService.writeToFolder(out), progress: { _ in }, isCancelled: { false },
                         skipped: { skipped.append($0) })
        #expect(skipped == ["b.png"])
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(files == ["Export problems.txt", "a (2).jpg", "a.jpg"], "\(files)")
        let report = try String(contentsOf: out.appendingPathComponent("Export problems.txt"), encoding: .utf8)
        #expect(report.contains("b.png"))
    }

    @Test func aFolderExportResumes() async throws {
        let (ex, entries, _) = try library()
        let out = Fixtures.tempDir()
        // the first run stops after one file, leaving a cut-off file behind
        var n = 0
        await #expect(throws: ExportError.self) {
            try await ex.run(entries, format: .jpeg, write: ExportService.writeToFolder(out), progress: { n = $0 },
                             isCancelled: { n >= 1 })
        }
        try Data("cut".utf8).write(to: out.appendingPathComponent(entries[1].path + ".partial"))
        var written: [String] = []
        let write = ExportService.writeToFolder(out)
        try await ex.run(entries, format: .jpeg, write: { e, u, d in written.append(e.path); try await write(e, u, d) },
                         progress: { _ in }, isCancelled: { false }, alreadyThere: ExportService.alreadyInFolder(out))
        #expect(written == [entries[1].path, entries[2].path])
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(files == entries.map(\.path).sorted(), "\(files)")
    }
}
