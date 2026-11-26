import Foundation

/// Lets background jobs (scans, thumbnail generation, face detection) step aside while the server
/// renders something a person is waiting for, e.g. thumbnails scrolling into view.
public enum InteractiveWork {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active = 0
    nonisolated(unsafe) private static var lastEnd = Date.distantPast

    public static func begin() {
        lock.lock(); active += 1; lock.unlock()
    }

    public static func end() {
        lock.lock(); active -= 1; lastEnd = Date(); lock.unlock()
    }

    /// Runs `work` as interactive.
    public static func run<T>(_ work: () async throws -> T) async rethrows -> T {
        begin()
        defer { end() }
        return try await work()
    }

    static var busy: Bool {
        lock.lock(); defer { lock.unlock() }
        // a short grace period: grid requests arrive in waves
        return active > 0 || Date().timeIntervalSince(lastEnd) < 0.3
    }

    /// Background loops call this between items: waits while interactive work is going on
    /// (at most `limit`, so a constant stream of requests can't stall a job forever).
    public static func yield(limit: TimeInterval = 5) {
        let until = Date().addingTimeInterval(limit)
        while busy && Date() < until { Thread.sleep(forTimeInterval: 0.05) }
    }
}
