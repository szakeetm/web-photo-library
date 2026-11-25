import Foundation

public struct AppPaths: Sendable {
    public let dataDir: URL
    public let defaultCacheDir: URL

    public init(dataDir: URL, defaultCacheDir: URL) {
        self.dataDir = dataDir
        self.defaultCacheDir = defaultCacheDir
    }

    public static func standard() -> AppPaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return AppPaths(
            dataDir: support.appendingPathComponent("PhotoServer", isDirectory: true),
            defaultCacheDir: caches.appendingPathComponent("PhotoServer", isDirectory: true)
        )
    }

    public var databaseURL: URL { dataDir.appendingPathComponent("library.sqlite") }
}
