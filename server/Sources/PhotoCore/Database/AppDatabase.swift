import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    /// The folder the database file is in (the data location); nil in memory.
    public let directory: URL?

    public init(path: String) throws {
        directory = URL(fileURLWithPath: path).deletingLastPathComponent()
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
        directory = nil
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
        m.registerMigration("v3-albums-search") { db in
            try db.execute(sql: """
                CREATE TABLE album (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    coverAssetId TEXT,
                    source TEXT NOT NULL DEFAULT 'user',
                    sourceKey TEXT UNIQUE);
                -- members reference assets by id without a foreign key: they survive while a photo is missing
                CREATE TABLE album_asset (
                    albumId INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
                    assetId TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (albumId, assetId));
                CREATE INDEX album_asset_asset ON album_asset(assetId);
                CREATE VIRTUAL TABLE search_index USING fts5(assetId UNINDEXED, text, tokenize = 'unicode61 remove_diacritics 2');
                """)
        }
        m.registerMigration("v4-catalog-id") { db in
            // Identifies this database to offline replicas (stored JSON-encoded like every setting).
            try db.execute(sql: """
                INSERT OR IGNORE INTO setting (key, value) VALUES ('catalogId', '"' || lower(hex(randomblob(16))) || '"')
                """)
        }
        m.registerMigration("v5-edits") { db in
            // Append-only edit history; the current version is asset.editVersion (0 = unedited).
            // No foreign key: edits survive while a photo is missing; purge removes them.
            try db.execute(sql: """
                CREATE TABLE edit (
                    assetId TEXT NOT NULL,
                    version INTEGER NOT NULL,
                    recipe TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    PRIMARY KEY (assetId, version));
                """)
        }
        m.registerMigration("v6-places-faces") { db in
            try db.execute(sql: """
                -- places: GeoNames id as key (stable across rebuilds of the bundled table)
                CREATE TABLE place (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    region TEXT,
                    country TEXT NOT NULL,
                    countryCode TEXT NOT NULL,
                    lat DOUBLE NOT NULL,
                    lon DOUBLE NOT NULL);
                ALTER TABLE asset ADD COLUMN placeId INTEGER;
                ALTER TABLE asset ADD COLUMN placeVersion INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX asset_place ON asset(placeId);

                -- people and faces; user decisions (names, assignments, rejections) are never undone by jobs
                CREATE TABLE person (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT,
                    coverFaceId INTEGER,
                    hidden BOOLEAN NOT NULL DEFAULT 0,
                    createdAt DATETIME NOT NULL);
                CREATE TABLE face (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    assetId TEXT NOT NULL,
                    x DOUBLE NOT NULL, y DOUBLE NOT NULL, w DOUBLE NOT NULL, h DOUBLE NOT NULL,
                    quality DOUBLE NOT NULL,
                    embedding BLOB NOT NULL,
                    personId INTEGER REFERENCES person(id) ON DELETE SET NULL,
                    assignment TEXT);
                CREATE INDEX face_asset ON face(assetId);
                CREATE INDEX face_person ON face(personId);
                CREATE TABLE face_reject (
                    faceId INTEGER NOT NULL REFERENCES face(id) ON DELETE CASCADE,
                    personId INTEGER NOT NULL REFERENCES person(id) ON DELETE CASCADE,
                    PRIMARY KEY (faceId, personId));
                ALTER TABLE asset ADD COLUMN facesVersion INTEGER NOT NULL DEFAULT 0;
                """)
        }
        m.registerMigration("v7-videos") { db in
            try db.execute(sql: """
                ALTER TABLE asset ADD COLUMN kind TEXT NOT NULL DEFAULT 'photo';
                ALTER TABLE asset ADD COLUMN duration DOUBLE;
                ALTER TABLE asset ADD COLUMN videoCodec TEXT;
                ALTER TABLE asset ADD COLUMN videoHDR BOOLEAN NOT NULL DEFAULT 0;
                ALTER TABLE asset ADD COLUMN servePlan TEXT;
                ALTER TABLE asset ADD COLUMN videoError TEXT;
                ALTER TABLE asset ADD COLUMN contentId TEXT;
                ALTER TABLE asset ADD COLUMN probeVersion INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX asset_contentId ON asset(contentId);

                -- Live Photo motion clips: attached to the still, not assets of their own
                CREATE TABLE motion (
                    assetId TEXT PRIMARY KEY,
                    root TEXT NOT NULL,
                    relPath TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    mtime DOUBLE NOT NULL,
                    codec TEXT,
                    UNIQUE (root, relPath));
                """)
        }
        m.registerMigration("v8-trash") { db in
            // Deleted uploads wait here (files untouched) until restored or deleted for good.
            try db.execute(sql: "CREATE TABLE trash (assetId TEXT PRIMARY KEY, trashedAt DATETIME NOT NULL)")
        }
        m.registerMigration("v9-objects") { db in
            // Things recognised in photos (Vision's classifier); asset.objectsVersion marks what's done.
            try db.execute(sql: """
                CREATE TABLE object_label (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE);
                CREATE TABLE asset_object (
                    assetId TEXT NOT NULL,
                    labelId INTEGER NOT NULL REFERENCES object_label(id) ON DELETE CASCADE,
                    confidence DOUBLE NOT NULL,
                    PRIMARY KEY (assetId, labelId));
                CREATE INDEX asset_object_label ON asset_object(labelId);
                ALTER TABLE asset ADD COLUMN objectsVersion INTEGER NOT NULL DEFAULT 0;
                """)
        }
        m.registerMigration("v10-meta-edit") { db in
            // The date read from the file (sidecar → EXIF → file date) is kept in asset.file*; a date the
            // user set lives in meta_edit and wins. asset.takenAt/tzOffset are always the effective date.
            try db.execute(sql: """
                ALTER TABLE asset ADD COLUMN fileTakenAt DATETIME;
                ALTER TABLE asset ADD COLUMN fileTzOffset INTEGER;
                ALTER TABLE asset ADD COLUMN fileDateSource TEXT;
                UPDATE asset SET fileTakenAt = takenAt, fileTzOffset = tzOffset, fileDateSource = dateSource;
                CREATE TABLE meta_edit (
                    assetId TEXT PRIMARY KEY,
                    takenAt DATETIME NOT NULL,
                    tzOffset INTEGER,
                    createdAt DATETIME NOT NULL);
                """)
        }
        m.registerMigration("v11-media-flags") { db in
            // Screenshots, selfies, portraits (filled by re-probing: probeVersion 2) and date added
            // (existing photos: their oldest file's modification date, the best guess available).
            try db.execute(sql: """
                ALTER TABLE asset ADD COLUMN mediaFlags INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE asset ADD COLUMN addedAt DATETIME;
                UPDATE asset SET addedAt = (SELECT datetime(MIN(f.mtime), 'unixepoch') FROM file f WHERE f.assetId = asset.id);
                UPDATE asset SET addedAt = takenAt WHERE addedAt IS NULL;
                """)
        }
        m.registerMigration("v12-text-duplicates") { db in
            // Text recognised in photos (searchable) and image fingerprints for finding duplicates.
            try db.execute(sql: """
                CREATE TABLE asset_text (assetId TEXT PRIMARY KEY, text TEXT NOT NULL);
                CREATE TABLE asset_print (
                    assetId TEXT PRIMARY KEY,
                    dhash INTEGER NOT NULL,
                    print BLOB NOT NULL);
                CREATE INDEX asset_print_dhash ON asset_print(dhash);
                CREATE TABLE duplicate_dismiss (groupKey TEXT PRIMARY KEY, createdAt DATETIME NOT NULL);
                ALTER TABLE asset ADD COLUMN textVersion INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE asset ADD COLUMN printVersion INTEGER NOT NULL DEFAULT 0;
                """)
        }
        m.registerMigration("v13-video-trim") { db in
            // Video trims (database only; applied when playing and exporting).
            try db.execute(sql: """
                CREATE TABLE video_trim (assetId TEXT PRIMARY KEY, start DOUBLE NOT NULL, "end" DOUBLE NOT NULL, createdAt DATETIME NOT NULL);
                """)
        }
        m.registerMigration("v14-file-name") { db in
            // The original name of a file stored under another one (Apple Photos keeps IMG_1234.HEIC as <UUID>.heic).
            try db.execute(sql: "ALTER TABLE file ADD COLUMN name TEXT")
        }
        return m
    }
}
