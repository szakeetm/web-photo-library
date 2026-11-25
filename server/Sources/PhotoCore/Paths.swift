import Foundation

/// Where the database and caches live. The location itself is recorded in a small
/// bootstrap file (config.json) in a fixed folder, because it can't live in the database.
public struct AppPaths: Sendable, Equatable {
    public let dataDir: URL

    public init(dataDir: URL) { self.dataDir = dataDir }

    public var databaseURL: URL { dataDir.appendingPathComponent("library.sqlite") }
    public var cacheDir: URL { dataDir.appendingPathComponent("cache", isDirectory: true) }

    /// ~/Library/Application Support/PhotoServer (override with PHOTOSERVER_HOME, e.g. for a second dev instance)
    public static var standardBootstrapDir: URL {
        if let home = ProcessInfo.processInfo.environment["PHOTOSERVER_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

/// Case-insensitive (APFS) path containment checks.
public enum PathOverlap {
    public static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }
    /// True when the paths are equal or one contains the other.
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        let x = normalized(a), y = normalized(b)
        return x == y || x.hasPrefix(y + "/") || y.hasPrefix(x + "/")
    }
}

public enum DataMoveError: Error, CustomStringConvertible {
    case sameLocation, nested, alreadyHasLibrary(String), notWritable(String), targetNotEmpty(String), overlapsLibrary
    public var description: String {
        switch self {
        case .sameLocation: "That is already the data location."
        case .nested: "The new location can't be inside the current one (or vice versa)."
        case .alreadyHasLibrary(let p): "\(p) already contains a library database."
        case .notWritable(let p): "Cannot write to \(p)."
        case .targetNotEmpty(let p): "\(p) already contains a \"cache\" folder. Choose an empty folder or a new one."
        case .overlapsLibrary: "The data location can't be inside the photo library (or contain it)."
        }
    }
}

public enum DataMover {
    /// Copies the database (consistent snapshot), caches and face model to `newDir`, switches the
    /// bootstrap config, then removes the old copies. A face model already in `newDir` is kept, and
    /// the old one is then left in place. The caller must restart to open the new database.
    public static func move(db: AppDatabase, from old: AppPaths, to newDir: URL, bootstrapDir: URL,
                            libraryPath: String? = nil) throws {
        let fm = FileManager.default
        if PathOverlap.normalized(old.dataDir.path) == PathOverlap.normalized(newDir.path) { throw DataMoveError.sameLocation }
        if PathOverlap.overlaps(old.dataDir.path, newDir.path) { throw DataMoveError.nested }
        if let lib = libraryPath, PathOverlap.overlaps(lib, newDir.path) { throw DataMoveError.overlapsLibrary }
        let new = AppPaths(dataDir: newDir)
        if fm.fileExists(atPath: new.databaseURL.path) { throw DataMoveError.alreadyHasLibrary(newDir.path) }
        if fm.fileExists(atPath: new.cacheDir.path) { throw DataMoveError.targetNotEmpty(newDir.path) }
        do { try fm.createDirectory(at: newDir, withIntermediateDirectories: true) } catch {
            throw DataMoveError.notWritable(newDir.path)
        }
        guard fm.isWritableFile(atPath: newDir.path) else { throw DataMoveError.notWritable(newDir.path) }

        // Only paths created by this call are ever removed on failure.
        var created: [URL] = []
        let oldModel = FaceAnalyzer.modelURL(dataDir: old.dataDir)
        let newModel = FaceAnalyzer.modelURL(dataDir: newDir)
        let moveModel = fm.fileExists(atPath: oldModel.path) && !fm.fileExists(atPath: newModel.path)
        do {
            try db.writer.writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [new.databaseURL.path]) }
            created.append(new.databaseURL)
            if fm.fileExists(atPath: old.cacheDir.path) {
                try fm.copyItem(at: old.cacheDir, to: new.cacheDir)
                created.append(new.cacheDir)
            }
            // Only the package: the compiled model next to it is rebuilt on first use.
            if moveModel {
                try fm.createDirectory(at: newModel.deletingLastPathComponent(), withIntermediateDirectories: true)
                created.append(newModel)
                try fm.copyItem(at: oldModel, to: newModel)
            }
            try Bootstrap.save(BootstrapConfig(dataDir: newDir.path), in: bootstrapDir)
        } catch {
            for url in created { try? fm.removeItem(at: url) }
            throw error
        }
        // Old copies are no longer referenced.
        try? fm.removeItem(at: old.cacheDir)
        if moveModel {
            let models = oldModel.deletingLastPathComponent()
            try? fm.removeItem(at: oldModel)
            try? fm.removeItem(at: models.appendingPathComponent("FaceNet.mlmodelc"))
            if (try? fm.contentsOfDirectory(atPath: models.path))?.isEmpty == true { try? fm.removeItem(at: models) }
        }
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(atPath: old.databaseURL.path + suffix)
        }
    }
}
