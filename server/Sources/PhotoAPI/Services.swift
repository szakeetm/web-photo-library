import Foundation
import PhotoCore

/// Everything the HTTP layer needs, wired once at startup.
public final class Services: @unchecked Sendable {
    public let paths: AppPaths
    public let db: AppDatabase
    public let settings: SettingsStore
    public let catalog: CatalogService
    public let jobs: JobRunner
    private let lock = NSLock()
    private var store: DerivativeStore?

    public init(paths: AppPaths, inMemory: Bool = false) throws {
        self.paths = paths
        try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
        db = inMemory ? try AppDatabase.inMemory() : try AppDatabase(path: paths.databaseURL.path)
        settings = SettingsStore(db: db)
        catalog = CatalogService(db: db, settings: settings)
        var getStore: (() -> DerivativeStore)!
        jobs = JobRunner(db: db, settings: settings, derivatives: { getStore() })
        getStore = { [unowned self] in self.derivatives() }
    }

    /// Derivative store for the currently configured cache directory.
    public func derivatives() -> DerivativeStore {
        let dir = (try? settings.get(.cacheDir)).flatMap { $0 }.map { URL(fileURLWithPath: $0) } ?? paths.defaultCacheDir
        lock.lock(); defer { lock.unlock() }
        if let s = store, s.cacheDir == dir { return s }
        let s = DerivativeStore(cacheDir: dir)
        store = s
        return s
    }
}
