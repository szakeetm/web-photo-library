import Foundation
import GRDB
import Testing
@testable import PhotoCore

/// The Trash for any photo: uploads moved, everything else only hidden.
@Suite struct PhotoTrashTests {
    struct Env {
        let db: AppDatabase
        let library: URL
        let uploads: URL
        let libId: String
        let upId: String
        func visible() throws -> Set<String> {
            Set(try db.writer.read { try CatalogService.catalogAssets($0, ids: nil, trashed: false).map(\.id) })
        }
        func rescan() throws {
            _ = try LibraryScanner(db: db, root: library, serverTZ: TimeZone(identifier: "UTC")!).detectChanges(progress: { _, _ in }, isCancelled: { false })
        }
    }

    func env() throws -> Env {
        let library = Fixtures.tempDir(), uploads = Fixtures.tempDir()
        Fixtures.writeJPEG(to: library.appendingPathComponent("Trip/a.jpg"), dateTimeOriginal: "2021:07:04 15:30:00", offset: "+02:00", color: (1, 0, 0))
        Fixtures.writeJPEG(to: uploads.appendingPathComponent("phone-uploads/b.jpg"), dateTimeOriginal: "2021:08:01 10:00:00", offset: "+02:00", color: (0, 1, 0))
        let db = try AppDatabase.inMemory()
        let tz = TimeZone(identifier: "UTC")!
        _ = try LibraryScanner(db: db, root: library, serverTZ: tz).detectChanges(progress: { _, _ in }, isCancelled: { false })
        _ = try LibraryScanner(db: db, root: uploads, rootName: Roots.uploads, serverTZ: tz).detectChanges(progress: { _, _ in }, isCancelled: { false })
        let id = { (root: String) in try db.writer.read { try String.fetchOne($0, sql: "SELECT assetId FROM file WHERE root = ?", arguments: [root])! } }
        return Env(db: db, library: library, uploads: uploads, libId: try id(Roots.library), upId: try id(Roots.uploads))
    }

    @Test func aLibraryPhotoIsHiddenAndItsFileUntouched() throws {
        let e = try env()
        let done = try PhotoTrash.trash(ids: [e.libId, e.upId], db: e.db, uploadsRoot: e.uploads)
        #expect(Set(done) == [e.libId, e.upId])
        #expect(try e.visible().isEmpty)
        // the library's file is where it was; the upload went to the uploads Trash
        #expect(FileManager.default.fileExists(atPath: e.library.appendingPathComponent("Trip/a.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: e.uploads.appendingPathComponent("phone-uploads/b.jpg").path))
        let items = try PhotoTrash.list(db: e.db)
        #expect(items.first { $0.asset.id == e.libId }?.virtual == true)
        #expect(items.first { $0.asset.id == e.upId }?.virtual == false)
        // a rescan doesn't bring it back
        try e.rescan()
        #expect(try e.visible().isEmpty)

        _ = try PhotoTrash.restore(ids: [e.libId, e.upId], db: e.db, uploadsRoot: e.uploads)
        #expect(try e.visible() == [e.libId, e.upId])
        #expect(FileManager.default.fileExists(atPath: e.uploads.appendingPathComponent("phone-uploads/b.jpg").path))
    }

    @Test func deletedForGoodStaysHiddenAndLeavesTheTrash() throws {
        let e = try env()
        _ = try PhotoTrash.trash(ids: [e.libId], db: e.db, uploadsRoot: e.uploads)
        let gone = try PhotoTrash.deleteForever(ids: nil, db: e.db, uploadsRoot: e.uploads)
        #expect(gone == [e.libId])
        #expect(try PhotoTrash.list(db: e.db).isEmpty)
        try e.rescan()
        #expect(try e.visible() == [e.upId])
        #expect(FileManager.default.fileExists(atPath: e.library.appendingPathComponent("Trip/a.jpg").path))
        // it can't be restored from the Trash any more
        #expect(try PhotoTrash.restore(ids: [e.libId], db: e.db, uploadsRoot: e.uploads).isEmpty)
    }

    @Test func hiddenPhotosExpireToHiddenForGood() throws {
        let e = try env()
        _ = try PhotoTrash.trash(ids: [e.libId], db: e.db, uploadsRoot: nil)   // no uploads folder: hidden still works
        #expect(try PhotoTrash.expire(db: e.db, uploadsRoot: nil, now: Date().addingTimeInterval(86_400 * 10)).isEmpty)
        #expect(try PhotoTrash.expire(db: e.db, uploadsRoot: nil, now: Date().addingTimeInterval(86_400 * 31)) == [e.libId])
        #expect(try PhotoTrash.list(db: e.db).isEmpty && !(try e.visible().contains(e.libId)))
    }
}
