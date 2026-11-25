import Foundation

/// Where the database and caches live. The location itself is recorded in a small
/// bootstrap file (config.json) in a fixed folder, because it can't live in the database.
public struct AppPaths: Sendable, Equatable {
    public let dataDir: URL

    public init(dataDir: URL) { self.dataDir = dataDir }

    public var databaseURL: URL { dataDir.appendingPathComponent("library.sqlite") }
    public var cacheDir: URL { dataDir.appendingPathComponent("cache", isDirectory: true) }

    /// ~/Library/Application Support/PhotoServer
    public static var standardBootstrapDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoServer", isDirectory: true)
    }

    public static func resolve(bootstrapDir: URL = standardBootstrapDir) -> AppPaths {
        if let dir = Bootstrap.load(from: bootstrapDir).dataDir, !dir.isEmpty {
            return AppPaths(dataDir: URL(fileURLWithPath: dir, isDirectory: true))
        }
        return AppPaths(dataDir: bootstrapDir)
    }
}

public struct BootstrapConfig: Codable, Sendable, Equatable {
    public var dataDir: String?
    public init(dataDir: String?) { self.dataDir = dataDir }
}

public enum Bootstrap {
    static func url(in dir: URL) -> URL { dir.appendingPathComponent("config.json") }

    public static func load(from dir: URL) -> BootstrapConfig {
        guard let data = try? Data(contentsOf: url(in: dir)),
              let cfg = try? JSONDecoder().decode(BootstrapConfig.self, from: data) else { return BootstrapConfig(dataDir: nil) }
        return cfg
    }

    public static func save(_ config: BootstrapConfig, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(config).write(to: url(in: dir), options: .atomic)
    }
}

public enum DataMoveError: Error, CustomStringConvertible {
    case sameLocation, nested, alreadyHasLibrary(String), notWritable(String)
    public var description: String {
        switch self {
        case .sameLocation: "That is already the data location."
        case .nested: "The new location can't be inside the current one (or vice versa)."
        case .alreadyHasLibrary(let p): "\(p) already contains a library database."
        case .notWritable(let p): "Cannot write to \(p)."
        }
    }
}

public enum DataMover {
    /// Copies the database (consistent snapshot) and caches to `newDir`, switches the bootstrap
    /// config, then removes the old copies. The caller must restart to open the new database.
    public static func move(db: AppDatabase, from old: AppPaths, to newDir: URL, bootstrapDir: URL) throws {
        let fm = FileManager.default
        let src = old.dataDir.standardizedFileURL.resolvingSymlinksInPath().path
        let dst = newDir.standardizedFileURL.resolvingSymlinksInPath().path
        if src == dst { throw DataMoveError.sameLocation }
        if dst.hasPrefix(src + "/") || src.hasPrefix(dst + "/") { throw DataMoveError.nested }
        let new = AppPaths(dataDir: newDir)
        if fm.fileExists(atPath: new.databaseURL.path) { throw DataMoveError.alreadyHasLibrary(newDir.path) }
        do { try fm.createDirectory(at: newDir, withIntermediateDirectories: true) } catch {
            throw DataMoveError.notWritable(newDir.path)
        }
        guard fm.isWritableFile(atPath: newDir.path) else { throw DataMoveError.notWritable(newDir.path) }

        try db.writer.writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [new.databaseURL.path]) }
        do {
            if fm.fileExists(atPath: old.cacheDir.path) {
                try fm.copyItem(at: old.cacheDir, to: new.cacheDir)
            }
            try Bootstrap.save(BootstrapConfig(dataDir: newDir.path), in: bootstrapDir)
        } catch {
            try? fm.removeItem(at: new.databaseURL)
            try? fm.removeItem(at: new.cacheDir)
            throw error
        }
        // Old copies are no longer referenced.
        try? fm.removeItem(at: old.cacheDir)
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(atPath: old.databaseURL.path + suffix)
        }
    }
}
