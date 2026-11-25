import Foundation
import PhotoCore

/// Everything the HTTP layer needs, wired once at startup.
public final class Services: @unchecked Sendable {
    public let paths: AppPaths
    public let bootstrapDir: URL
    /// Called after the data location moved; the process must reopen the database.
    public let restart: @Sendable () -> Void
    public let db: AppDatabase
    public let settings: SettingsStore
    public let catalog: CatalogService
    public let jobs: JobRunner
    private let lock = NSLock()
    private var store: DerivativeStore?

    public init(paths: AppPaths, bootstrapDir: URL = AppPaths.standardBootstrapDir, inMemory: Bool = false,
                restart: @escaping @Sendable () -> Void = {}) throws {
        self.paths = paths
        self.bootstrapDir = bootstrapDir
        self.restart = restart
        try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
        db = inMemory ? try AppDatabase.inMemory() : try AppDatabase(path: paths.databaseURL.path)
        settings = SettingsStore(db: db)
        catalog = CatalogService(db: db, settings: settings)
        var getStore: (() -> DerivativeStore)!
        jobs = JobRunner(db: db, settings: settings, derivatives: { getStore() })
        getStore = { [unowned self] in self.derivatives() }
    }

    public func derivatives() -> DerivativeStore {
        lock.lock(); defer { lock.unlock() }
        if let s = store { return s }
        let s = DerivativeStore(cacheDir: paths.cacheDir)
        store = s
        return s
    }
}
