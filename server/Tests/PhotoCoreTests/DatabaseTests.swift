import Testing
import GRDB
import Foundation
@testable import PhotoCore

@Suite struct DatabaseTests {
    @Test func migrationsCreateTables() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.writer.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        for t in ["asset", "file", "folder", "setting", "job", "change_log"] {
            #expect(tables.contains(t), "missing table \(t)")
        }
    }

    @Test func fileUniquePath() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { d in
            _ = try Folder(id: nil, relPath: "", parentId: nil, name: "").inserted(d)
            var a = Asset.placeholder(id: "h1")
            try a.insert(d)
            a = Asset.placeholder(id: "h2")
            try a.insert(d)
            _ = try FileRow(id: nil, assetId: "h1", relPath: "x.jpg", folderId: 1, size: 1, mtime: 0, sidecarRelPath: nil).inserted(d)
        }
        #expect(throws: (any Error).self) {
            try db.writer.write { d in
                _ = try FileRow(id: nil, assetId: "h2", relPath: "x.jpg", folderId: 1, size: 1, mtime: 0, sidecarRelPath: nil).inserted(d)
            }
        }
    }

    @Test func v1DatabaseMigratesKeepingRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v1-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { d in
            try d.execute(sql: "INSERT INTO folder (id, relPath, parentId, name) VALUES (1, '', NULL, ''), (2, 'Trip', 1, 'Trip')")
            try d.execute(sql: "INSERT INTO asset (id, width, height, mime, takenAt, dateSource, favorite) VALUES ('h1', 1, 1, 'x', '2021-01-01', 'exif', 1)")
            try d.execute(sql: "INSERT INTO file (assetId, relPath, folderId, size, mtime) VALUES ('h1', 'Trip/a.jpg', 2, 10, 1.5)")
        }
        try queue.close()
        let db = try AppDatabase(path: url.path)
        let files = try db.writer.read { try FileRow.fetchAll($0) }
        let folders = try db.writer.read { try Folder.fetchAll($0) }
        #expect(files.count == 1 && files[0].root == "library" && files[0].folderId == 2)
        #expect(folders.count == 2 && folders.allSatisfy { $0.root == "library" })
        #expect(try db.writer.read { try Asset.fetchOne($0, key: "h1")?.favorite } == true)
    }

    @Test func v7MigrationDefaults() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6-places-faces")
        try queue.write { d in
            try d.execute(sql: "INSERT INTO asset (id, width, height, mime, takenAt, dateSource, favorite) VALUES ('h1', 1, 1, 'x', '2021-01-01', 'exif', 0)")
        }
        try AppDatabase.migrator.migrate(queue)
        let a = try queue.read { try Asset.fetchOne($0, key: "h1") }
        #expect(a?.kind == "photo")
        #expect(a?.probeVersion == 0)
        #expect(a?.videoHDR == false)
        #expect(a?.duration == nil)
        try queue.write { d in
            try MotionRow(assetId: "h1", root: "library", relPath: "a.mov", size: 1, mtime: 0, codec: "hevc").insert(d)
        }
        #expect(throws: (any Error).self) {
            try queue.write { d in
                try MotionRow(assetId: "h2", root: "library", relPath: "a.mov", size: 1, mtime: 0, codec: nil).insert(d)
            }
        }
    }
}
