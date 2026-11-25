import Testing
import Foundation
import GRDB
@testable import PhotoCore

@Suite struct DataLocationTests {
    @Test func defaultsToBootstrapDir() {
        let boot = Fixtures.tempDir()
        let p = AppPaths.resolve(bootstrapDir: boot)
        #expect(p.dataDir == boot)
        #expect(p.databaseURL == boot.appendingPathComponent("library.sqlite"))
        #expect(p.cacheDir == boot.appendingPathComponent("cache", isDirectory: true))
    }

    @Test func configOverridesDataDir() throws {
        let boot = Fixtures.tempDir()
        let target = Fixtures.tempDir()
        try Bootstrap.save(BootstrapConfig(dataDir: target.path), in: boot)
        #expect(AppPaths.resolve(bootstrapDir: boot).dataDir.path == target.path)
    }

    @Test func moveCopiesDatabaseAndCachesAndSwitchesConfig() throws {
        let boot = Fixtures.tempDir()
        let old = AppPaths.resolve(bootstrapDir: boot)
        let db = try AppDatabase(path: old.databaseURL.path)
        try SettingsStore(db: db).set(.libraryPath, "/x")
        let thumb = old.cacheDir.appendingPathComponent("thumb/ab/abc_e0.heic")
        try FileManager.default.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("img".utf8).write(to: thumb)

        let dest = Fixtures.tempDir().appendingPathComponent("Photos Data")
        try DataMover.move(db: db, from: old, to: dest, bootstrapDir: boot)

        let new = AppPaths.resolve(bootstrapDir: boot)
        #expect(new.dataDir.standardizedFileURL.path == dest.standardizedFileURL.path)
        let moved = try AppDatabase(path: new.databaseURL.path)
        #expect(try SettingsStore(db: moved).get(.libraryPath) == "/x")
        #expect(FileManager.default.fileExists(atPath: new.cacheDir.appendingPathComponent("thumb/ab/abc_e0.heic").path))
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
        #expect(!FileManager.default.fileExists(atPath: old.databaseURL.path))
    }

    @Test func moveRejectsFolderWithExistingLibrary() throws {
        let boot = Fixtures.tempDir()
        let old = AppPaths.resolve(bootstrapDir: boot)
        let db = try AppDatabase(path: old.databaseURL.path)
        let dest = Fixtures.tempDir()
        try Data().write(to: dest.appendingPathComponent("library.sqlite"))
        #expect(throws: DataMoveError.self) { try DataMover.move(db: db, from: old, to: dest, bootstrapDir: boot) }
        #expect(AppPaths.resolve(bootstrapDir: boot).dataDir == boot)
    }

    @Test func moveRejectsNestedLocation() throws {
        let boot = Fixtures.tempDir()
        let old = AppPaths.resolve(bootstrapDir: boot)
        let db = try AppDatabase(path: old.databaseURL.path)
        #expect(throws: DataMoveError.self) {
            try DataMover.move(db: db, from: old, to: boot.appendingPathComponent("cache/inner"), bootstrapDir: boot)
        }
    }

    @Test func moveNeverDeletesExistingCacheFolderInTarget() throws {
        let boot = Fixtures.tempDir()
        let old = AppPaths.resolve(bootstrapDir: boot)
        let db = try AppDatabase(path: old.databaseURL.path)
        try FileManager.default.createDirectory(at: old.cacheDir.appendingPathComponent("thumb"), withIntermediateDirectories: true)
        let dest = Fixtures.tempDir()
        let keep = dest.appendingPathComponent("cache/keep.txt")
        try FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: keep)
        #expect(throws: DataMoveError.self) { try DataMover.move(db: db, from: old, to: dest, bootstrapDir: boot) }
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("library.sqlite").path))
    }

    @Test func moveRejectsNestedCaseInsensitive() throws {
        let boot = Fixtures.tempDir()
        let old = AppPaths.resolve(bootstrapDir: boot)
        let db = try AppDatabase(path: old.databaseURL.path)
        let upper = URL(fileURLWithPath: boot.path.uppercased()).appendingPathComponent("inner")
        #expect(throws: DataMoveError.self) { try DataMover.move(db: db, from: old, to: upper, bootstrapDir: boot) }
    }

    @Test func moveRejectsLocationOverlappingLibrary() throws {
        let boot = Fixtures.tempDir()
        let old = AppPaths.resolve(bootstrapDir: boot)
        let db = try AppDatabase(path: old.databaseURL.path)
        let library = Fixtures.tempDir()
        #expect(throws: DataMoveError.self) {
            try DataMover.move(db: db, from: old, to: library.appendingPathComponent("data"), bootstrapDir: boot, libraryPath: library.path)
        }
        #expect(throws: DataMoveError.self) {
            try DataMover.move(db: db, from: old, to: library.deletingLastPathComponent(), bootstrapDir: boot, libraryPath: library.path)
        }
    }

    @Test func overlapHelper() {
        #expect(PathOverlap.overlaps("/a/b", "/a/b/c"))
        #expect(PathOverlap.overlaps("/A/B/c", "/a/b"))
        #expect(PathOverlap.overlaps("/a/b", "/a/b"))
        #expect(!PathOverlap.overlaps("/a/b", "/a/bc"))
    }
}
