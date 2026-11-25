import Foundation
import PhotoCore

/// Everything the HTTP layer needs, wired once at startup.
public final class Services: @unchecked Sendable {
    public let paths: AppPaths
    public let bootstrapDir: URL
    /// Called after the data location moved; the process must reopen the database.
    public let restart: @Sendable () -> Void
    /// The configured (non-default) data folder doesn't exist, e.g. its drive is unplugged.
    /// The server then runs on a throwaway in-memory database so Settings can explain and fix it.
    public let dataLocationMissing: Bool
    public let db: AppDatabase
    public let settings: SettingsStore
    public let catalog: CatalogService
    public let albums: AlbumService
    public let edits: EditService
    public let jobs: JobRunner
    public let videos: VideoConversions
    /// The ffmpeg used for video previews and posters; nil when it isn't installed.
    public let ffmpeg: URL?
    private let lock = NSLock()
    private var store: DerivativeStore?

    public init(paths: AppPaths, bootstrapDir: URL = AppPaths.standardBootstrapDir, inMemory: Bool = false,
                restart: @escaping @Sendable () -> Void = {}, ffmpeg: URL? = FFmpeg.locate()) throws {
        self.paths = paths
        self.ffmpeg = ffmpeg
        self.bootstrapDir = bootstrapDir
        self.restart = restart
        let configured = Bootstrap.load(from: bootstrapDir).dataDir.map { PathOverlap.normalized($0) == PathOverlap.normalized(paths.dataDir.path) } ?? false
        dataLocationMissing = !inMemory && configured && !FileManager.default.fileExists(atPath: paths.dataDir.path)
        if dataLocationMissing {
            db = try AppDatabase.inMemory()
        } else {
            try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
            db = inMemory ? try AppDatabase.inMemory() : try AppDatabase(path: paths.databaseURL.path)
        }
        settings = SettingsStore(db: db)
        catalog = CatalogService(db: db, settings: settings)
        albums = AlbumService(db: db, settings: settings)
        let box = StoreBox()
        edits = EditService(db: db, catalog: catalog, derivatives: { box.get() })
        var getStore: (() -> DerivativeStore)!
        jobs = JobRunner(db: db, settings: settings, derivatives: { getStore() }, excluding: [paths.dataDir], dataDir: paths.dataDir)
        videos = VideoConversions(db: db, catalog: catalog, cacheDir: paths.cacheDir, ffmpeg: ffmpeg)
        getStore = { [unowned self] in self.derivatives() }
        box.get = getStore
        jobs.onPurge = { [videos] ids in ids.forEach(videos.remove(id:)) }
        jobs.onClearCaches = { [videos] in try videos.clear() }
        if let up = try? settings.get(.uploadsPath) { UploadSession.cleanIncoming(uploadsRoot: URL(fileURLWithPath: up)) }
    }

    public func derivatives() -> DerivativeStore {
        lock.lock(); defer { lock.unlock() }
        if let s = store { return s }
        let s = DerivativeStore(cacheDir: paths.cacheDir)
        do { try s.upgradeIfNeeded() } catch { print("Could not clear outdated thumbnails and previews: \(error)") }
        store = s
        return s
    }
}

/// Late-bound access to the derivative store for services created before `self` is complete.
final class StoreBox: @unchecked Sendable {
    var get: () -> DerivativeStore = { fatalError("derivative store not ready") }
}
