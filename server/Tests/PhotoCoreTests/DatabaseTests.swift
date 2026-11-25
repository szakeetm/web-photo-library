import Testing
import GRDB
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
}
