import Foundation
import GRDB

/// More library folders on this Mac (or its drives), next to the library folder: read-only, scanned
/// the same way. The same photo in several folders is one photo.
public struct LocalFolderSource: Codable, Sendable, Equatable {
    public var id: Int
    public var path: String

    public init(id: Int, path: String) {
        self.id = id
        self.path = path
    }

    public var root: String { LocalFolders.rootPrefix + String(id) }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var title: String { url.lastPathComponent }
}

extension SettingKey where T == [LocalFolderSource] {
    public static let localFolders = SettingKey("localFolders", default: [])
}

public enum LocalFolderError: Error, CustomStringConvertible {
    case notAFolder(String), unreadable(String), overlaps(String)
    public var description: String {
        switch self {
        case .notAFolder(let p): "Folder does not exist: \(p)"
        case .unreadable(let p): "Folder is not readable: \(p). Grant PhotoServer Full Disk Access."
        case .overlaps(let what): "That folder can't contain \(what), or be inside it."
        }
    }
}

public enum LocalFolders {
    public static let rootPrefix = "folder-"

    public static func isLocalFolder(_ root: String) -> Bool { root.hasPrefix(rootPrefix) }

    public static func all(_ settings: SettingsStore) throws -> [LocalFolderSource] { try settings.get(.localFolders) }

    public static func source(root: String, _ settings: SettingsStore) throws -> LocalFolderSource? {
        try all(settings).first { $0.root == root }
    }

    /// Checks `path` is a readable folder that doesn't overlap the other folders, and adds it.
    public static func add(path: String, _ settings: SettingsStore, dataDir: URL) throws -> LocalFolderSource {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw LocalFolderError.notAFolder(path) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { throw LocalFolderError.unreadable(path) }
        var others: [(String, String)] = [("the app's data location", dataDir.path)]
        if let lib = try settings.get(.libraryPath) { others.append(("the library folder", lib)) }
        if let up = try settings.get(.uploadsPath) { others.append(("the uploads folder", up)) }
        others += try all(settings).map { ("another library folder", $0.path) }
        others += try PhotosLibraries.all(settings).map { ("a Photos library", $0.path) }
        if let hit = others.first(where: { PathOverlap.overlaps($0.1, url.path) }) { throw LocalFolderError.overlaps(hit.0) }
        var list = try all(settings)
        let s = LocalFolderSource(id: (list.map(\.id).max() ?? 0) + 1, path: url.path)
        list.append(s)
        try settings.set(.localFolders, list)
        return s
    }

    /// Removes a folder: its files and folders are forgotten, and the photos only there are removed for
    /// good with everything about them (albums, edits, Trash…). Nothing in the folder is touched.
    /// Returns the removed photos.
    @discardableResult
    public static func remove(id: Int, db: AppDatabase, _ settings: SettingsStore) throws -> [String] {
        var list = try all(settings)
        guard let s = list.first(where: { $0.id == id }) else { return [] }
        let purged = try AssetPurge.removeRoot(s.root, scanner: LibraryScanner(db: db, root: s.url, rootName: s.root), db: db)
        list.removeAll { $0.id == id }
        try settings.set(.localFolders, list)
        try settings.set(.sourceScans, try settings.get(.sourceScans).filter { $0.root != s.root })
        return purged
    }
}

extension LibraryScanner {
    /// Shows this root's top folder with `title` (a source's name).
    public func nameRootFolder(_ title: String) throws {
        let id = try ensureFolders([""])[""]!
        try db.writer.write { d in
            guard try String.fetchOne(d, sql: "SELECT name FROM folder WHERE id = ?", arguments: [id]) != title else { return }
            try d.execute(sql: "UPDATE folder SET name = ? WHERE id = ?", arguments: [title, id])
            try ChangeLog.record(d, entity: "folder", id: String(id), op: "upsert")
        }
    }
}
