import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: path, configuration: config)
        self.writer = pool
        try Self.migrator.migrate(pool)
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        return try AppDatabase(writer: DatabaseQueue(configuration: config))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "asset") { t in
                t.primaryKey("id", .text)
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("mime", .text).notNull()
                t.column("takenAt", .datetime).notNull().indexed()
                t.column("tzOffset", .integer)
                t.column("dateSource", .text).notNull()
                t.column("lat", .double)
                t.column("lon", .double)
                t.column("locationSource", .text)
                t.column("cameraMake", .text)
                t.column("cameraModel", .text)
                t.column("lens", .text)
                t.column("iso", .double)
                t.column("aperture", .double)
                t.column("shutter", .double)
                t.column("focal", .double)
                t.column("description", .text)
                t.column("favorite", .boolean).notNull().defaults(to: false)
                t.column("favoriteUserSet", .boolean).notNull().defaults(to: false)
                t.column("blurhash", .text)
                t.column("editVersion", .integer).notNull().defaults(to: 0)
                t.column("missingSince", .datetime)
            }
            try db.create(table: "folder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("relPath", .text).notNull().unique()
                t.column("parentId", .integer).references("folder", onDelete: .cascade)
                t.column("name", .text).notNull()
            }
            try db.create(table: "file") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("assetId", .text).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("relPath", .text).notNull().unique()
                t.column("folderId", .integer).notNull().indexed().references("folder", onDelete: .cascade)
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("sidecarRelPath", .text)
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "job") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("state", .text).notNull()
                t.column("phase", .text)
                t.column("progress", .integer).notNull().defaults(to: 0)
                t.column("total", .integer).notNull().defaults(to: 0)
                t.column("message", .text)
                t.column("error", .text)
                t.column("startedAt", .datetime)
                t.column("endedAt", .datetime)
            }
            try db.create(table: "change_log") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("entity", .text).notNull()
                t.column("entityId", .text).notNull()
                t.column("op", .text).notNull()
            }
        }
        m.registerMigration("v2-roots") { db in
            // file/folder rows belong to a root (library | uploads); paths are unique per root.
            try db.execute(sql: """
                CREATE TABLE folder_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    relPath TEXT NOT NULL,
                    parentId INTEGER REFERENCES folder(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    root TEXT NOT NULL DEFAULT 'library',
                    UNIQUE(root, relPath));
                INSERT INTO folder_new (id, relPath, parentId, name, root) SELECT id, relPath, parentId, name, 'library' FROM folder;
                CREATE TABLE file_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    assetId TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    relPath TEXT NOT NULL,
                    folderId INTEGER NOT NULL REFERENCES folder(id) ON DELETE CASCADE,
                    size INTEGER NOT NULL,
                    mtime DOUBLE NOT NULL,
                    sidecarRelPath TEXT,
                    root TEXT NOT NULL DEFAULT 'library',
                    UNIQUE(root, relPath));
                INSERT INTO file_new (id, assetId, relPath, folderId, size, mtime, sidecarRelPath, root)
                    SELECT id, assetId, relPath, folderId, size, mtime, sidecarRelPath, 'library' FROM file;
                DROP TABLE file;
                DROP TABLE folder;
                ALTER TABLE folder_new RENAME TO folder;
                ALTER TABLE file_new RENAME TO file;
                CREATE INDEX file_assetId ON file(assetId);
                CREATE INDEX file_folderId ON file(folderId);
                """)
        }
        return m
    }
}
