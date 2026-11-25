import Testing
import Foundation
@testable import PhotoCore

@Suite struct SettingsTests {
    @Test func defaultLibraryPathIsNil() throws {
        let s = SettingsStore(db: try AppDatabase.inMemory())
        #expect(try s.get(.libraryPath) == nil)
    }

    @Test func roundTrip() throws {
        let s = SettingsStore(db: try AppDatabase.inMemory())
        try s.set(.libraryPath, "/Volumes/Photos")
        #expect(try s.get(.libraryPath) == "/Volumes/Photos")
        let all = try s.all()
        #expect(all["libraryPath"] == .string("/Volumes/Photos"))
    }

    @Test func listsOnlyVisibleDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("file.jpg"))
        let listing = try DirectoryBrowser.list(root.path)
        #expect(listing.entries.map(\.name) == ["A", "b"])
        #expect(listing.entries.allSatisfy { $0.readable })
        #expect(listing.parent == root.deletingLastPathComponent().path)
    }

    @Test func listingMissingDirThrows() {
        #expect(throws: (any Error).self) { try DirectoryBrowser.list("/nonexistent/\(UUID())") }
    }
}
