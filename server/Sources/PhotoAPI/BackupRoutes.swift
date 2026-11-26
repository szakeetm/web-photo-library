import Foundation
import Hummingbird
import PhotoCore

/// rclone on this Mac (path and version), looked up once a minute at most.
enum RcloneInfo {
    struct Info: Encodable, Sendable { let path: String; let version: String }
    private static let cache = LockedValue<(at: Date, info: Info?)?>(nil)

    static func current() -> Info? {
        if let c = cache.get(), Date().timeIntervalSince(c.at) < 60 { return c.info }
        let info = Rclone.locate().map { r -> Info in
            let first = (try? r.run(["version"])).map { String(decoding: $0, as: UTF8.self) }?.split(separator: "\n").first
            return Info(path: r.binary.path, version: first.map(String.init) ?? "rclone")
        }
        cache.set((Date(), info))
        return info
    }
}

final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
}

extension APIRoutes {
    struct BackupStatus: Encodable {
        let rclone: RcloneInfo.Info?
        let enabled: Bool
        let destination: String
        let defaultDestination: String
        let intervalHours: Int
        let last: BackupReport?
        let activity: BackupActivity?
        /// when the next scheduled backup runs (nil when off)
        let nextAt: Date?
        /// what there is to back up now
        let local: BackupService.LocalStats
        /// why the last restore attempt failed
        let restoreError: String?
    }
    struct BackupPatch: Decodable { var enabled: Bool?; var destination: String?; var intervalHours: Int? }
    struct LocationBody: Decodable { let location: String }
    struct PathBody: Decodable { let path: String }
    struct Folders: Encodable { let path: String; let folders: [String] }

    func registerBackupRoutes(on api: RouterGroup<BasicRequestContext>) {
        let services = self.services
        let backup = services.backup
        let restoreError = LockedValue<String?>(nil)

        @Sendable func status() throws -> BackupStatus {
            let s = services.settings
            let enabled = try s.get(.backupEnabled)
            let last = try s.get(.lastBackup)
            let interval = try backup.intervalHours()
            var next: Date?
            if enabled {
                next = last.map { $0.startedAt.addingTimeInterval($0.ok ? TimeInterval(interval) * 3600 : 3600) } ?? Date()
                if let n = next, n < Date() { next = Date() }
            }
            return BackupStatus(rclone: RcloneInfo.current(), enabled: enabled, destination: try backup.destination(),
                                defaultDestination: BackupService.defaultDestination, intervalHours: interval, last: last,
                                activity: backup.current, nextAt: next, local: try backup.localStats(), restoreError: restoreError.get())
        }
        @Sendable func rclone() throws -> Rclone {
            guard let r = Rclone.locate() else { throw HTTPError(.conflict, message: RcloneError.notInstalled.description) }
            return r
        }
        @Sendable func rcloneCall<T: Encodable & Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> Response {
            do { return try json(try await blocking(work)) } catch let e as RcloneError {
                return errorResponse(.badRequest, e.description)
            } catch let e as BackupError {
                return errorResponse(.conflict, e.description)
            }
        }

        api.get("backup") { _, _ in try json(try await blocking { try status() }) }

        api.put("backup") { req, ctx in
            let body = try await req.decode(as: BackupPatch.self, context: ctx)
            if let d = body.destination {
                let t = d.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return errorResponse(.badRequest, "Choose where to back up to.") }
                try services.settings.set(.backupDestination, t == BackupService.defaultDestination ? nil : t)
            }
            if let h = body.intervalHours {
                guard (1...24 * 30).contains(h) else { return errorResponse(.badRequest, "Back up between every hour and every 30 days.") }
                try services.settings.set(.backupIntervalHours, h == BackupService.defaultIntervalHours ? nil : h)
            }
            if let e = body.enabled {
                if e && Rclone.locate() == nil { return errorResponse(.conflict, RcloneError.notInstalled.description) }
                try services.settings.set(.backupEnabled, e)
            }
            return try json(try await blocking { try status() })
        }

        // Backs up now, in the background (GET /backup shows how it goes).
        api.post("backup/run") { _, _ in
            guard Rclone.locate() != nil else { return errorResponse(.conflict, RcloneError.notInstalled.description) }
            guard backup.current == nil else { return errorResponse(.conflict, BackupError.busy.description) }
            Thread.detachNewThread { _ = try? backup.backup() }
            // let it register, so the answer already shows it running
            for _ in 0..<20 where backup.current == nil { try await Task.sleep(for: .milliseconds(10)) }
            return try json(try await blocking { try status() })
        }

        // rclone's remotes and their folders, for choosing a destination or a backup to restore.
        api.get("rclone/remotes") { _, _ in
            try await rcloneCall { try rclone().remotes() }
        }
        api.get("rclone/folders") { req, _ in
            guard let path = req.uri.queryParameters.get("path"), !path.isEmpty else { throw HTTPError(.badRequest) }
            return try await rcloneCall { Folders(path: path, folders: try rclone().folders(path)) }
        }
        api.post("rclone/folders") { req, ctx in
            let body = try await req.decode(as: PathBody.self, context: ctx)
            return try await rcloneCall {
                try rclone().makeFolder(body.path)
                return Folders(path: body.path, folders: [])
            }
        }

        // Library folders on rclone remotes: added (then scanned), removed.
        api.post("sources") { req, ctx in
            let body = try await req.decode(as: PathBody.self, context: ctx)
            let path = body.path.trimmingCharacters(in: .whitespaces)
            guard let r = Rclone.locate() else { return errorResponse(.conflict, RcloneError.notInstalled.description) }
            if try RemoteSources.all(services.settings).contains(where: { $0.path == path }) {
                return errorResponse(.conflict, "\(path) is already a source.")
            }
            let entry: Rclone.Entry?
            do { entry = try await blocking { try r.stat(path) } } catch let e as RcloneError {
                return errorResponse(.badRequest, e.description)
            }
            guard let entry, entry.IsDir else { return errorResponse(.badRequest, "\(path) isn't a folder rclone can read.") }
            _ = try RemoteSources.add(path: path, services.settings)
            _ = services.jobs.enqueue(.detectChanges)
            return try settingsResponse()
        }
        api.delete("sources/:id") { _, ctx in
            guard let id = ctx.parameters.get("id", as: Int.self) else { throw HTTPError(.badRequest) }
            if services.jobs.current() != nil { return errorResponse(.conflict, "Wait for running jobs to finish first.") }
            let purged = try await blocking { try RemoteSources.remove(id: id, db: services.db, services.settings, dataDir: services.paths.dataDir) }
            let store = services.derivatives()
            for a in purged { store.remove(id: a); services.videos.remove(id: a) }
            return try settingsResponse()
        }

        // More library folders on this Mac: added (then scanned), removed.
        api.post("local-folders") { req, ctx in
            let body = try await req.decode(as: PathBody.self, context: ctx)
            do { _ = try LocalFolders.add(path: body.path, services.settings, dataDir: services.paths.dataDir) } catch let e as LocalFolderError {
                return errorResponse(.badRequest, e.description)
            }
            _ = services.jobs.enqueue(.detectChanges)
            return try settingsResponse()
        }
        api.delete("local-folders/:id") { _, ctx in
            guard let id = ctx.parameters.get("id", as: Int.self) else { throw HTTPError(.badRequest) }
            if services.jobs.current() != nil { return errorResponse(.conflict, "Wait for running jobs to finish first.") }
            let purged = try await blocking { try LocalFolders.remove(id: id, db: services.db, services.settings) }
            let store = services.derivatives()
            for a in purged { store.remove(id: a); services.videos.remove(id: a) }
            return try settingsResponse()
        }

        api.delete("library-folder") { _, _ in
            if services.jobs.current() != nil { return errorResponse(.conflict, "Wait for running jobs to finish first.") }
            let purged = try await blocking { try LocalFolders.removeLibrary(db: services.db, services.settings) }
            let store = services.derivatives()
            for a in purged { store.remove(id: a); services.videos.remove(id: a) }
            return try settingsResponse()
        }

        // Apple Photos libraries on this Mac: added (then scanned), removed.
        api.post("photos-libraries") { req, ctx in
            let body = try await req.decode(as: PathBody.self, context: ctx)
            if try PhotosLibraries.all(services.settings).contains(where: { $0.path == URL(fileURLWithPath: body.path).standardizedFileURL.path }) {
                return errorResponse(.conflict, "That Photos library is already a source.")
            }
            do { _ = try PhotosLibraries.add(path: body.path, services.settings) } catch let e as PhotosLibraryError {
                return errorResponse(.badRequest, e.description)
            }
            _ = services.jobs.enqueue(.detectChanges)
            return try settingsResponse()
        }
        api.delete("photos-libraries/:id") { _, ctx in
            guard let id = ctx.parameters.get("id", as: Int.self) else { throw HTTPError(.badRequest) }
            if services.jobs.current() != nil { return errorResponse(.conflict, "Wait for running jobs to finish first.") }
            let purged = try await blocking { try PhotosLibraries.remove(id: id, db: services.db, services.settings) }
            let store = services.derivatives()
            for a in purged { store.remove(id: a); services.videos.remove(id: a) }
            return try settingsResponse()
        }

        // What a backup holds and whether it can be restored here.
        api.get("backup/inspect") { req, _ in
            guard let location = req.uri.queryParameters.get("location"), !location.isEmpty else { throw HTTPError(.badRequest) }
            return try await rcloneCall { try backup.inspect(location) }
        }

        // Restores a backup in the background, then restarts the server with it.
        api.post("backup/restore") { req, ctx in
            let body = try await req.decode(as: LocationBody.self, context: ctx)
            if services.dataLocationMissing { return errorResponse(.conflict, "The data location is unavailable.") }
            if services.jobs.current() != nil { return errorResponse(.conflict, "Wait for running jobs to finish first.") }
            guard backup.current == nil else { return errorResponse(.conflict, BackupError.busy.description) }
            // the checks run first, so a backup that can't be restored is refused right away
            let inspection = try await blocking { try backup.inspect(body.location) }
            guard inspection.canRestore else {
                return errorResponse(.conflict, BackupError.cannotRestore(inspection.checks.filter { !$0.ok }.map(\.detail)).description)
            }
            restoreError.set(nil)
            let restart = services.restart
            Thread.detachNewThread {
                do {
                    try backup.restore(body.location)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { restart() }
                } catch {
                    restoreError.set((error as? CustomStringConvertible)?.description ?? error.localizedDescription)
                }
            }
            for _ in 0..<20 where backup.current == nil { try await Task.sleep(for: .milliseconds(10)) }
            return try json(try await blocking { try status() })
        }
    }
}
