import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct RootsTests {
    struct Env { let db: AppDatabase; let lib: URL; let up: URL; let runner: JobRunner; let catalog: CatalogService }

    func env() throws -> Env {
        let lib = Fixtures.tempDir(), up = Fixtures.tempDir()
        Fixtures.writeJPEG(to: lib.appendingPathComponent("Trip/a.jpg"), color: (1, 0, 0))
        Fixtures.writeJPEG(to: up.appendingPathComponent("phone-uploads/2024-07/b.jpg"), color: (0, 1, 0))
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try settings.set(.libraryPath, lib.path)
        try settings.set(.uploadsPath, up.path)
        let store = DerivativeStore(cacheDir: Fixtures.tempDir())
        let runner = JobRunner(db: db, settings: settings, derivatives: { store }, serverTZ: TimeZone(identifier: "UTC")!)
        runner.enqueue(.detectChanges)
        runner.waitUntilIdle()
        return Env(db: db, lib: lib, up: up, runner: runner, catalog: CatalogService(db: db, settings: settings))
    }

    @Test func bothRootsIndexed() throws {
        let e = try env()
        #expect(try e.catalog.catalog().assets.count == 2)
        let roots = Set(try e.catalog.folderTree().filter { $0.relPath.isEmpty }.map(\.root))
        #expect(roots == ["library", "uploads"])
    }

    @Test func movedFromUploadsToLibraryKeepsAsset() throws {
        let e = try env()
        let src = e.up.appendingPathComponent("phone-uploads/2024-07/b.jpg")
        let id = try FileHasher.sha256(url: src)
        try e.db.writer.write { try $0.execute(sql: "UPDATE asset SET favorite = 1, favoriteUserSet = 1 WHERE id = ?", arguments: [id]) }
        try FileManager.default.moveItem(at: src, to: e.lib.appendingPathComponent("Trip/b.jpg"))
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        let a = try #require(try e.db.writer.read { try Asset.fetchOne($0, key: id) })
        #expect(a.favorite && a.missingSince == nil)
        let files = try e.db.writer.read { try FileRow.filter(Column("assetId") == id).fetchAll($0) }
        #expect(files.map(\.root) == ["library"] && files.map(\.relPath) == ["Trip/b.jpg"])
        #expect(try e.catalog.sourceURL(id: id)?.path.hasSuffix("Trip/b.jpg") == true)
    }

    @Test func sameRelPathInBothRoots() throws {
        let e = try env()
        Fixtures.writeJPEG(to: e.up.appendingPathComponent("Trip/a.jpg"), color: (0, 0, 1))
        e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        #expect(try e.db.writer.read { try FileRow.filter(Column("relPath") == "Trip/a.jpg").fetchCount($0) } == 2)
        #expect(try e.catalog.catalog().assets.count == 3)
    }

    @Test func unreadableUploadsRootLeavesRowsAlone() throws {
        let e = try env()
        chmod(e.up.path, 0o000)
        defer { chmod(e.up.path, 0o755) }
        let id = e.runner.enqueue(.detectChanges)
        e.runner.waitUntilIdle()
        let job = try #require(e.runner.job(id: id))
        #expect(job.state == "done")
        #expect(job.message?.contains("Uploads folder") == true)
        #expect(try e.catalog.catalog().assets.count == 2)
    }
}
