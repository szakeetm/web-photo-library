import Foundation

public struct DirEntry: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var readable: Bool
}

public struct DirListing: Codable, Sendable, Equatable {
    public var path: String
    public var parent: String?
    public var entries: [DirEntry]
}

public enum DirectoryBrowser {
    /// Lists visible subdirectories of `path` (directories only, no files).
    public static func list(_ path: String) throws -> DirListing {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: url.path)
        var entries: [DirEntry] = []
        for name in names where !name.hasPrefix(".") {
            let child = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            entries.append(DirEntry(name: name, path: child.path, readable: fm.isReadableFile(atPath: child.path)))
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let parent = url.path == "/" ? nil : url.deletingLastPathComponent().path
        return DirListing(path: url.path, parent: parent, entries: entries)
    }
}
