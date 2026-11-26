import Foundation
import GRDB

/// Points a source at the place its folder was moved to. Its photos and everything done to them
/// stay: they belong to the source's root ("library", "folder-<n>", "remote-<n>"), not its path, and
/// the next scan finds the same files under the new path.
public enum SourceRelocation {
    public enum Failure: Error, CustomStringConvertible {
        case notTheFolder(String)
        public var description: String {
            switch self {
            case .notTheFolder(let p): "None of the folder's photos are in \(p): is it the folder that was moved?"
            }
        }
    }

    /// Up to `limit` paths (relative to the root) of files indexed from `root`, spread over it.
    public static func sample(root: String, db: AppDatabase, limit: Int = 20) throws -> [String] {
        try db.writer.read { d in
            try String.fetchAll(d, sql: "SELECT relPath FROM file WHERE root = ? ORDER BY random() LIMIT ?", arguments: [root, limit])
        }
    }

    /// Re-points a folder on this Mac: the old library folder (`root` "library") or a local folder.
    /// The new place must be a readable folder, overlap no other source, and hold some of its photos.
    public static func relocateLocal(root: String, to path: String, db: AppDatabase, _ settings: SettingsStore, dataDir: URL) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw LocalFolderError.notAFolder(path) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { throw LocalFolderError.unreadable(path) }
        var others: [(String, String)] = [("the app's data location", dataDir.path)]
        if root != Roots.library, let lib = try settings.get(.libraryPath) { others.append(("another local folder", lib)) }
        if let up = try settings.get(.uploadsPath) { others.append(("the uploads folder", up)) }
        others += try LocalFolders.all(settings).filter { $0.root != root }.map { ("another local folder", $0.path) }
        others += try PhotosLibraries.all(settings).map { ("a Photos library", $0.path) }
        if let hit = others.first(where: { PathOverlap.overlaps($0.1, url.path) }) { throw LocalFolderError.overlaps(hit.0) }
        let files = try sample(root: root, db: db)
        if !files.isEmpty, !files.contains(where: { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }) {
            throw Failure.notTheFolder(url.path)
        }
        if root == Roots.library {
            try settings.set(.libraryPath, url.path)
        } else {
            var list = try LocalFolders.all(settings)
            guard let i = list.firstIndex(where: { $0.root == root }) else { return }
            list[i].path = url.path
            try settings.set(.localFolders, list)
        }
        try forgetLastScan(root, settings)
    }

    /// Re-points an rclone folder. `found` says which of the sampled files are under the new path
    /// (one rclone listing); some of them must be.
    public static func relocateRemote(id: Int, to path: String, db: AppDatabase, _ settings: SettingsStore,
                                      found: ([String]) throws -> Set<String>) throws {
        var list = try RemoteSources.all(settings)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let files = try sample(root: list[i].root, db: db)
        if !files.isEmpty, try found(files).isEmpty { throw Failure.notTheFolder(path) }
        list[i].path = path
        try settings.set(.remoteSources, list)
        try forgetLastScan(list[i].root, settings)
    }

    static func forgetLastScan(_ root: String, _ settings: SettingsStore) throws {
        try settings.set(.sourceScans, try settings.get(.sourceScans).filter { $0.root != root })
    }
}
