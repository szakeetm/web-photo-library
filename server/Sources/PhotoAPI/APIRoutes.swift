import Foundation
import Hummingbird
import HTTPTypes
import PhotoCore

struct ErrorBody: Encodable { let error: String; var updateRequired: Bool? = nil }

func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.withoutEscapingSlashes]
    var buffer = ByteBuffer()
    buffer.writeBytes(try enc.encode(value))
    return Response(status: status, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
                    body: .init(byteBuffer: buffer))
}

func errorResponse(_ status: HTTPResponse.Status, _ message: String, updateRequired: Bool? = nil) -> Response {
    (try? json(ErrorBody(error: message, updateRequired: updateRequired), status: status)) ?? Response(status: status)
}

/// Runs blocking work off the cooperative thread pool.
func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            cont.resume(with: Result { try work() })
        }
    }
}

/// On-demand thumbnail/preview rendering shares the hardware codec; keep a few at a time.
let renderLimiter = AsyncLimiter(limit: 4)
/// One upload per content hash at a time.
let uploadLocks = KeyedLock()

struct APIRoutes {
    let services: Services
    let webRoot: URL?

    /// Build id of the served web app (SvelteKit writes _app/version.json).
    var webVersion: String? {
        guard let root = webRoot,
              let data = try? Data(contentsOf: root.appendingPathComponent("_app/version.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }
    let fileIO = FileIO()

    struct Health: Encodable {
        let ok: Bool; let version: String; let apiVersion: Int; let uploadsConfigured: Bool
        let webVersion: String?; let libraryConfigured: Bool
        let mapStyleURL: String
        let commit: String?; let commitDate: String?; let dirty: Bool
    }
    struct SettingsBody: Codable {
        var libraryPath: String?; var uploadsPath: String?; var ownerLogin: String?
        var facesEnabled: Bool?; var mapStyleURL: String?
    }
    struct SettingsResponse: Encodable {
        let libraryPath: String?; let uploadsPath: String?; let ownerLogin: String?
        let dataDir: String; let cacheBytes: Int64; let databaseBytes: Int64; let dataLocationMissing: Bool
        let facesEnabled: Bool; let faceModelInstalled: Bool; let faceModelPath: String
        let mapStyleURL: String?; let defaultMapStyleURL: String
    }
    static let defaultMapStyle = "https://tiles.openfreemap.org/styles/liberty"
    struct PersonPatch: Decodable { var name: String??; var hidden: Bool?; var coverFaceId: Int64? }
    struct MergeBody: Decodable { let ids: [Int64]; let into: Int64 }
    struct FacePatch: Decodable { let personId: Int64? }
    struct NewPerson: Decodable { let name: String; let faceIds: [Int64] }
    struct Created: Encodable { let id: Int64 }
    struct MoveBody: Decodable { let path: String }
    struct UploadResponse: Encodable { let asset: CatalogAsset?; let duplicate: Bool }
    struct NewAlbum: Decodable { let title: String; var assetIds: [String]? }
    struct AlbumPatch: Decodable { var title: String?; var coverAssetId: String? }
    struct AlbumMembers: Decodable { var add: [String]?; var remove: [String]?; var order: [String]? }
    struct FavoriteBody: Decodable { let ids: [String]; let favorite: Bool }
    struct DeleteBody: Decodable { let ids: [String] }
    struct TrashBody: Decodable { let ids: [String]? }
    struct DeleteResponse: Encodable { let deleted: [String] }
    struct SearchResult: Encodable { let ids: [String] }
    struct MoveResponse: Encodable { let dataDir: String; let restarting: Bool }
    struct Jobs: Encodable { let current: JobRow?; let recent: [JobRow] }
    struct SaveEdit: Decodable { let recipe: EditRecipe }
    struct Edited: Encodable { let asset: CatalogAsset }
    struct AutoRecipe: Encodable { let recipe: EditRecipe }
    struct Enqueued: Encodable { let id: Int64 }

    func register(on router: Router<BasicRequestContext>) {
        let api = router.group("api")

        api.get("health") { _, _ in
            try json(Health(ok: true, version: serverVersion, apiVersion: apiVersion,
                            uploadsConfigured: ((try? services.settings.get(.uploadsPath)).flatMap { $0 }) != nil,
                            webVersion: webVersion,
                            libraryConfigured: ((try? services.settings.get(.libraryPath)).flatMap { $0 }) != nil,
                            mapStyleURL: ((try? services.settings.get(.mapStyleURL)).flatMap { $0 }) ?? Self.defaultMapStyle,
                            commit: BuildInfo.current.commit, commitDate: BuildInfo.current.commitDate, dirty: BuildInfo.current.dirty))
        }

        api.get("settings") { _, _ in try settingsResponse() }

        api.put("settings") { req, ctx in
            let body = try await req.decode(as: SettingsBody.self, context: ctx)
            if let p = body.libraryPath {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
                    return errorResponse(.badRequest, "Folder does not exist: \(p)")
                }
                guard (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil else {
                    return errorResponse(.badRequest, "Folder is not readable: \(p). Grant PhotoServer Full Disk Access.")
                }
                if PathOverlap.overlaps(p, services.paths.dataDir.path) {
                    return errorResponse(.badRequest, "The library can't contain the app's data location (\(services.paths.dataDir.path)), or be inside it.")
                }
                if let up = try services.settings.get(.uploadsPath), PathOverlap.overlaps(p, up) {
                    return errorResponse(.badRequest, "The library and the uploads folder can't contain each other.")
                }
                try services.settings.set(.libraryPath, p)
            }
            if let u = body.uploadsPath {
                if u.isEmpty {
                    try services.settings.set(.uploadsPath, nil)
                } else {
                    if PathOverlap.overlaps(u, services.paths.dataDir.path) {
                        return errorResponse(.badRequest, "The uploads folder can't contain the app's data location, or be inside it.")
                    }
                    if let lib = try services.settings.get(.libraryPath), PathOverlap.overlaps(u, lib) {
                        return errorResponse(.badRequest, "The uploads folder must be outside the library (the library is never written to).")
                    }
                    // Symlinks only resolve once the folder exists: create it, re-check the real path,
                    // and undo the creation if it turns out to be inside the library or data location.
                    let existed = FileManager.default.fileExists(atPath: u)
                    if !existed {
                        var parent = URL(fileURLWithPath: u).deletingLastPathComponent()
                        while !FileManager.default.fileExists(atPath: parent.path) { parent.deleteLastPathComponent() }
                        let real = PathOverlap.normalized(parent.path)
                        if let lib = try services.settings.get(.libraryPath).map(PathOverlap.normalized), real == lib || real.hasPrefix(lib + "/") {
                            return errorResponse(.badRequest, "The uploads folder must be outside the library (the library is never written to).")
                        }
                    }
                    do { try FileManager.default.createDirectory(atPath: u, withIntermediateDirectories: true) } catch {
                        return errorResponse(.badRequest, "Cannot create \(u).")
                    }
                    let lib = try services.settings.get(.libraryPath)
                    if (lib.map { PathOverlap.overlaps(u, $0) } ?? false) || PathOverlap.overlaps(u, services.paths.dataDir.path) {
                        if !existed { try? FileManager.default.removeItem(atPath: u) }
                        return errorResponse(.badRequest, "The uploads folder must be outside the library and the data location.")
                    }
                    guard FileManager.default.isWritableFile(atPath: u) else {
                        return errorResponse(.badRequest, "The uploads folder is not writable: \(u).")
                    }
                    try services.settings.set(.uploadsPath, u)
                }
            }
            if let o = body.ownerLogin { try services.settings.set(.ownerLogin, o.isEmpty ? nil : o) }
            if let f = body.facesEnabled {
                try services.settings.set(.facesEnabled, f)
                if f { services.jobs.enqueueFacesIfNeeded() }
            }
            if let m = body.mapStyleURL {
                let t = m.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, !(t.hasPrefix("https://") || t.hasPrefix("http://")) {
                    return errorResponse(.badRequest, "The map style must be an http(s) URL.")
                }
                try services.settings.set(.mapStyleURL, t.isEmpty ? nil : t)
            }
            return try settingsResponse()
        }

        api.post("data/move") { req, ctx in
            let body = try await req.decode(as: MoveBody.self, context: ctx)
            if services.dataLocationMissing { return errorResponse(.conflict, "The data location is unavailable.") }
            if services.jobs.current() != nil || services.jobs.recent(limit: 5).contains(where: { $0.state == "queued" }) {
                return errorResponse(.conflict, "Wait for running jobs to finish first.")
            }
            let target = URL(fileURLWithPath: body.path, isDirectory: true)
            if let up = try services.settings.get(.uploadsPath), PathOverlap.overlaps(up, target.path) {
                return errorResponse(.badRequest, "The data location can't be inside the uploads folder (or contain it).")
            }
            do {
                try await blocking {
                    try DataMover.move(db: services.db, from: services.paths, to: target, bootstrapDir: services.bootstrapDir,
                                       libraryPath: try services.settings.get(.libraryPath))
                }
            } catch let e as DataMoveError {
                return errorResponse(.badRequest, e.description)
            }
            let restart = services.restart
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { restart() }
            return try json(MoveResponse(dataDir: target.path, restarting: true))
        }

        api.post("data/reset") { _, _ in
            // Only used to recover when the configured data folder is gone.
            guard services.dataLocationMissing else { return errorResponse(.conflict, "The data location is available.") }
            try Bootstrap.save(BootstrapConfig(dataDir: nil), in: services.bootstrapDir)
            let restart = services.restart
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { restart() }
            return try json(MoveResponse(dataDir: services.bootstrapDir.path, restarting: true))
        }

        api.get("fs/list") { req, _ in
            let path = req.uri.queryParameters.get("path") ?? FileManager.default.homeDirectoryForCurrentUser.path
            do { return try json(try DirectoryBrowser.list(path)) } catch {
                return errorResponse(.badRequest, "Cannot list \(path)")
            }
        }

        api.post("jobs/:kind") { _, ctx in
            guard let kind = ctx.parameters.get("kind").flatMap(JobKind.init(rawValue:)) else {
                return errorResponse(.badRequest, "Unknown job kind")
            }
            return try json(Enqueued(id: services.jobs.enqueue(kind)))
        }
        api.delete("jobs/:kind") { _, ctx in
            guard let id = ctx.parameters.get("kind", as: Int64.self) else { return errorResponse(.badRequest, "Bad id") }
            services.jobs.cancel(id: id)
            return Response(status: .noContent)
        }
        api.get("jobs") { _, _ in
            try json(Jobs(current: services.jobs.current(), recent: services.jobs.recent(limit: 10)))
        }

        api.get("catalog") { _, _ in
            let snap = try await blocking { try services.catalog.catalog() }
            return try json(snap)
        }
        api.get("catalog/changes") { req, _ in
            let since = req.uri.queryParameters.get("since", as: Int64.self) ?? -1
            let catalogId = req.uri.queryParameters.get("catalog")
            let delta = try await blocking { try services.catalog.changes(since: since, catalogId: catalogId) }
            return try json(delta)
        }
        api.get("folders") { _, _ in try json(try services.catalog.folderTree()) }

        api.get("assets/:id") { _, ctx in
            guard let id = validId(ctx), let detail = try services.catalog.asset(id: id) else { throw HTTPError(.notFound) }
            return try json(detail)
        }

        // Albums
        api.get("albums") { _, _ in try json(try services.albums.list()) }
        api.post("albums") { req, ctx in
            let body = try await req.decode(as: NewAlbum.self, context: ctx)
            return try albumCall { try json(try services.albums.create(title: body.title, assetIds: body.assetIds ?? [])) }
        }
        api.patch("albums/:album") { req, ctx in
            let body = try await req.decode(as: AlbumPatch.self, context: ctx)
            guard let id = ctx.parameters.get("album", as: Int64.self) else { throw HTTPError(.notFound) }
            return try albumCall {
                try services.albums.update(id: id, title: body.title, coverAssetId: body.coverAssetId)
                return try json(try services.albums.list().first { $0.id == id })
            }
        }
        api.delete("albums/:album") { _, ctx in
            guard let id = ctx.parameters.get("album", as: Int64.self) else { throw HTTPError(.notFound) }
            return try albumCall {
                try services.albums.delete(id: id)
                return Response(status: .noContent)
            }
        }
        api.post("albums/:album/assets") { req, ctx in
            let body = try await req.decode(as: AlbumMembers.self, context: ctx)
            guard let id = ctx.parameters.get("album", as: Int64.self) else { throw HTTPError(.notFound) }
            return try albumCall {
                try services.albums.modify(id: id, add: body.add ?? [], remove: body.remove ?? [], order: body.order)
                return try json(try services.albums.list().first { $0.id == id })
            }
        }

        // Favourites (batch) and search
        api.patch("assets") { req, ctx in
            let body = try await req.decode(as: FavoriteBody.self, context: ctx)
            try services.albums.setFavorite(ids: body.ids, favorite: body.favorite)
            return Response(status: .noContent)
        }
        api.get("search") { req, _ in
            let q = req.uri.queryParameters.get("q") ?? ""
            let ids = try await blocking { try services.albums.search(q) }
            return try json(SearchResult(ids: ids))
        }

        // People and faces
        let faces = FaceService(db: services.db)
        api.get("people") { _, _ in try json(try faces.people()) }
        api.post("people") { req, ctx in
            let body = try await req.decode(as: NewPerson.self, context: ctx)
            let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return errorResponse(.badRequest, "A name is required.") }
            return try peopleCall { try json(Created(id: try faces.createPerson(name: name, faceIds: body.faceIds))) }
        }
        api.patch("people/:person") { req, ctx in
            guard let id = ctx.parameters.get("person", as: Int64.self) else { throw HTTPError(.notFound) }
            let body = try await req.decode(as: PersonPatch.self, context: ctx)
            return try peopleCall {
                try faces.update(personId: id, name: body.name, hidden: body.hidden, coverFaceId: body.coverFaceId)
                return Response(status: .noContent)
            }
        }
        api.post("people/merge") { req, ctx in
            let body = try await req.decode(as: MergeBody.self, context: ctx)
            return try peopleCall {
                try faces.merge(sources: body.ids, into: body.into)
                return Response(status: .noContent)
            }
        }
        api.get("people/:person/faces") { _, ctx in
            guard let id = ctx.parameters.get("person", as: Int64.self) else { throw HTTPError(.notFound) }
            return try json(try faces.faces(personId: id))
        }
        api.patch("faces/:face") { req, ctx in
            guard let id = ctx.parameters.get("face", as: Int64.self) else { throw HTTPError(.notFound) }
            let body = try await req.decode(as: FacePatch.self, context: ctx)
            return try peopleCall {
                try faces.assign(faceId: id, to: body.personId)
                return Response(status: .noContent)
            }
        }
        api.get("faces/:face/thumb") { _, ctx in
            guard let id = ctx.parameters.get("face", as: Int64.self), let f = try faces.face(id: id) else { throw HTTPError(.notFound) }
            let store = services.derivatives()
            var preview = store.url(id: f.assetId, kind: .preview, format: .heic)
            if !store.exists(id: f.assetId, kind: .preview, format: .heic) {
                guard let src = try services.catalog.sourceURL(id: f.assetId) else { throw HTTPError(.notFound) }
                preview = try await renderLimiter.run { try await blocking { try store.ensure(id: f.assetId, source: src, kind: .preview, format: .heic) } }
            }
            let base = preview
            let url = try await renderLimiter.run { try await blocking { try faces.thumbnail(faceId: id, preview: base, cacheDir: store.cacheDir) } }
            let body = try await fileIO.loadFile(path: url.path, context: ctx)
            return Response(status: .ok, headers: [.contentType: "image/jpeg", .cacheControl: "public, max-age=31536000, immutable"], body: body)
        }

        // Editing
        api.get("assets/:id/edits") { _, ctx in
            guard let id = validId(ctx), let h = try services.edits.history(id: id) else { throw HTTPError(.notFound) }
            return try json(h)
        }
        api.post("assets/:id/edits") { req, ctx in
            guard let id = validId(ctx) else { throw HTTPError(.notFound) }
            if try isVideo(id) { return Self.notEditable }
            let body: SaveEdit
            do { body = try await req.decode(as: SaveEdit.self, context: ctx) } catch {
                return errorResponse(.badRequest, "Invalid edit.")
            }
            let edits = services.edits
            return try await editCall {
                let asset = try await renderLimiter.run { try await blocking { try edits.save(id: id, recipe: body.recipe) } }
                return try json(Edited(asset: asset))
            }
        }
        api.post("assets/:id/revert") { _, ctx in
            guard let id = validId(ctx) else { throw HTTPError(.notFound) }
            let edits = services.edits
            return try await editCall { try json(Edited(asset: try await blocking { try edits.revert(id: id) })) }
        }
        api.post("assets/:id/auto-enhance") { _, ctx in
            guard let id = validId(ctx) else { throw HTTPError(.notFound) }
            if try isVideo(id) { return Self.notEditable }
            let edits = services.edits
            return try await editCall { try json(AutoRecipe(recipe: try await blocking { try edits.autoEnhance(id: id) })) }
        }
        api.get("assets/:id/export") { req, ctx in
            guard let id = validId(ctx) else { throw HTTPError(.notFound) }
            if try isVideo(id) { return Self.notEditable }
            let format = req.uri.queryParameters.get("fmt").flatMap(ImageFormat.init(rawValue:)) ?? .jpeg
            let edits = services.edits
            return try await editCall {
                let (url, name) = try await renderLimiter.run { try await blocking { try edits.export(id: id, format: format) } }
                let body = try await fileIO.loadFile(path: url.path, context: ctx)
                return Response(status: .ok, headers: [
                    .contentType: format.mimeType,
                    .contentDisposition: "attachment; filename*=UTF-8''\(percentEncoded(name))",
                    .cacheControl: "private, no-store",
                ], body: body)
            }
        }

        api.head("assets/:id") { _, ctx in
            guard let id = validId(ctx), try services.catalog.catalogAsset(id: id) != nil else { throw HTTPError(.notFound) }
            return Response(status: .ok)
        }

        api.post("uploads") { req, ctx in try await upload(req, ctx) }

        // The Trash for uploads: deleting moves uploaded photos there (anything in the library is
        // refused); they can be restored, or deleted from disk for good.
        @Sendable func validIds(_ ids: [String]) -> Bool { ids.allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } }
        @Sendable func uploadsRoot() throws -> URL? {
            try services.settings.get(.uploadsPath).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        @Sendable func trashCall(_ work: @escaping @Sendable () throws -> [String], purged: Bool = false) async throws -> Response {
            let services = self.services
            do {
                let ids = try await blocking(work)
                if purged {
                    let store = services.derivatives()
                    for id in ids { store.remove(id: id); services.videos.remove(id: id) }
                }
                return try json(DeleteResponse(deleted: ids))
            } catch let e as UploadDeleteError {
                switch e {
                case .notFound: return errorResponse(.notFound, e.description)
                case .notAnUpload: return errorResponse(.forbidden, e.description)
                case .fileError: return errorResponse(.internalServerError, e.description)
                }
            }
        }
        let db = services.db
        api.post("uploads/delete") { req, ctx in
            let body = try await req.decode(as: DeleteBody.self, context: ctx)
            guard validIds(body.ids) else { throw HTTPError(.badRequest) }
            guard let root = try uploadsRoot() else { return errorResponse(.conflict, UploadError.notConfigured.description) }
            return try await trashCall { try UploadTrash.trash(ids: body.ids, db: db, uploadsRoot: root) }
        }
        api.get("trash") { _, _ in
            if let root = try uploadsRoot() {
                let gone = (try? await blocking { try UploadTrash.expire(db: db, uploadsRoot: root) }) ?? []
                let store = services.derivatives()
                for id in gone { store.remove(id: id); services.videos.remove(id: id) }
            }
            let items = try await blocking { try UploadTrash.list(db: db) }
            var res = try json(items)
            res.headers[.cacheControl] = "no-store"
            return res
        }
        api.post("trash/restore") { req, ctx in
            let body = try await req.decode(as: DeleteBody.self, context: ctx)
            guard validIds(body.ids) else { throw HTTPError(.badRequest) }
            guard let root = try uploadsRoot() else { return errorResponse(.conflict, UploadError.notConfigured.description) }
            return try await trashCall { try UploadTrash.restore(ids: body.ids, db: db, uploadsRoot: root) }
        }
        // ids omitted: empty the Trash
        api.post("trash/delete") { req, ctx in
            let body = try await req.decode(as: TrashBody.self, context: ctx)
            guard validIds(body.ids ?? []) else { throw HTTPError(.badRequest) }
            guard let root = try uploadsRoot() else { return errorResponse(.conflict, UploadError.notConfigured.description) }
            return try await trashCall({ try UploadTrash.deleteForever(ids: body.ids, db: db, uploadsRoot: root) }, purged: true)
        }

        api.get("assets/:id/original") { req, ctx in
            guard let id = validId(ctx), let url = try services.catalog.sourceURL(id: id) else { throw HTTPError(.notFound) }
            return try await fileResponse(path: url.path, contentType: contentType(forExtension: url.pathExtension), request: req,
                                          context: ctx, extraHeaders: [
                                              .contentDisposition: "attachment; filename*=UTF-8''\(percentEncoded(url.lastPathComponent))",
                                              .cacheControl: Self.originalCache,
                                          ])
        }

        for kind in DerivativeKind.allCases {
            api.get("\(kind.rawValue)/:id") { req, ctx in try await derivative(kind, req, ctx) }
        }

        // The photo's HDR gain map for the editor (NormalizedGainMap wire format); 204 for SDR photos.
        api.get("gainmap/:id") { _, ctx in
            guard let id = validId(ctx), let source = try services.catalog.sourceURL(id: id) else { throw HTTPError(.notFound) }
            let cache = "public, max-age=31536000, immutable"
            if try isVideo(id) { return Response(status: .noContent, headers: [.cacheControl: cache]) }
            let store = services.derivatives()
            let data = try await renderLimiter.run { try await blocking { try store.ensureGainMap(id: id, source: source) } }
            guard let data else { return Response(status: .noContent, headers: [.cacheControl: cache]) }
            return Response(status: .ok, headers: [.contentType: "application/octet-stream", .cacheControl: cache],
                            body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }

        registerVideoRoutes(on: api)
    }

    func upload(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let uploadsPath = try services.settings.get(.uploadsPath) else {
            return errorResponse(.conflict, UploadError.notConfigured.description)
        }
        let root = URL(fileURLWithPath: uploadsPath, isDirectory: true)
        let source = req.uri.queryParameters.get("source").flatMap(UploadSource.init(rawValue:)) ?? .desktop
        let name = req.uri.queryParameters.get("name") ?? "upload"
        let clientMTime = req.uri.queryParameters.get("mtime", as: Double.self).map { Date(timeIntervalSince1970: $0 / 1000) }

        // 1. receive into .incoming while hashing
        let session = try UploadSession(uploadsRoot: root)
        let received: UploadSession.Result
        do {
            for try await chunk in req.body {
                try session.write(Data(buffer: chunk))
            }
            received = try session.finish()
        } catch UploadError.tooLarge {
            return errorResponse(.contentTooLarge, UploadError.tooLarge.description)
        } catch {
            session.abort()
            throw error
        }

        // 2–4 run under a per-content lock so simultaneous uploads of the same photo write one copy.
        let services = self.services
        return try await uploadLocks.withLock(received.sha256) {
            do {
                // uploading a photo that is in the Trash brings it back
                _ = try UploadTrash.restore(ids: [received.sha256], db: services.db, uploadsRoot: root)
                if let existing = try services.catalog.catalogAsset(id: received.sha256) {
                    try? FileManager.default.removeItem(at: received.tempURL)
                    return try json(UploadResponse(asset: existing, duplicate: true))
                }
                guard let probe = ImageProbe.probe(url: received.tempURL),
                      let finalName = UploadPlacer.filename(name, mime: probe.mime) else {
                    try? FileManager.default.removeItem(at: received.tempURL)
                    return errorResponse(.unsupportedMediaType, UploadError.notAnImage.description)
                }
                let meta = MetadataResolver.resolve(probe: probe, sidecar: nil, fileMTime: clientMTime ?? Date(), serverTZ: .current)
                let asset: CatalogAsset? = try await renderLimiter.run {
                    try await blocking {
                        let rel = try UploadPlacer.place(temp: received.tempURL, uploadsRoot: root, source: source, name: finalName,
                                                         takenAt: meta.takenAt, tzOffset: meta.tzOffset)
                        let fileURL = root.appendingPathComponent(rel)
                        if let clientMTime { try? FileManager.default.setAttributes([.modificationDate: clientMTime], ofItemAtPath: fileURL.path) }
                        let scanner = LibraryScanner(db: services.db, root: root, rootName: Roots.uploads)
                        let id = try scanner.indexFile(relPath: rel)
                        try? services.jobs.render(assetId: id, source: fileURL)
                        try? PlaceService(db: services.db).geocodePending(ids: [id])
                        services.jobs.enqueueFacesIfNeeded()
                        return try services.catalog.catalogAsset(id: id)
                    }
                }
                return try json(UploadResponse(asset: asset, duplicate: false))
            } catch {
                try? FileManager.default.removeItem(at: received.tempURL)  // no-op once placed
                throw error
            }
        }
    }

    func percentEncoded(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_.~"))) ?? "photo"
    }

    func editCall(_ work: () async throws -> Response) async throws -> Response {
        do { return try await work() } catch EditError.notFound {
            return errorResponse(.notFound, EditError.notFound.description)
        } catch EditError.sourceUnavailable {
            return errorResponse(.conflict, EditError.sourceUnavailable.description)
        } catch let e as EditRecipe.Invalid {
            if case .schema = e { return errorResponse(.conflict, e.description, updateRequired: true) }
            return errorResponse(.badRequest, e.description)
        } catch let e as EditRenderError {
            return errorResponse(.internalServerError, e.description)
        }
    }

    func peopleCall(_ work: () throws -> Response) throws -> Response {
        do { return try work() } catch PeopleError.notFound {
            return errorResponse(.notFound, PeopleError.notFound.description)
        }
    }

    func albumCall(_ work: () throws -> Response) throws -> Response {
        do { return try work() } catch AlbumError.notFound {
            return errorResponse(.notFound, AlbumError.notFound.description)
        } catch AlbumError.emptyTitle {
            return errorResponse(.badRequest, AlbumError.emptyTitle.description)
        }
    }

    static var notEditable: Response { errorResponse(.badRequest, "Videos can't be edited.") }

    func isVideo(_ id: String) throws -> Bool { try services.catalog.kind(id: id) == "video" }

    func validId(_ ctx: BasicRequestContext) -> String? {
        guard let id = ctx.parameters.get("id"), id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        return id
    }

    func derivative(_ kind: DerivativeKind, _ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let id = validId(ctx) else { throw HTTPError(.notFound) }
        let format = req.uri.queryParameters.get("fmt").flatMap(ImageFormat.init(rawValue:)) ?? .heic
        let ev = req.uri.queryParameters.get("e", as: Int.self) ?? 0
        guard ev >= 0 else { throw HTTPError(.notFound) }
        let store = services.derivatives()
        let url: URL
        if try isVideo(id) {
            // Videos have no edits; their poster is the thumbnail and preview.
            guard ev == 0 else { throw HTTPError(.notFound) }
            if store.exists(id: id, kind: kind, format: format) {
                url = store.url(id: id, kind: kind, format: format)
            } else {
                guard let source = try services.catalog.sourceURL(id: id) else { throw HTTPError(.notFound) }
                let made = try await renderLimiter.run {
                    try await blocking { try store.ensurePoster(id: id, source: source, format: format, ffmpeg: services.ffmpeg) }
                }
                url = kind == .thumb ? made.thumb : made.preview
            }
        } else if ev > 0, store.exists(id: id, kind: kind, editVersion: ev, format: format) {
            url = store.url(id: id, kind: kind, editVersion: ev, format: format)
        } else {
            guard let source = try services.catalog.sourceURL(id: id) else { throw HTTPError(.notFound) }
            if ev > 0 {
                // Edited renders are regenerated from the stored recipe (e.g. after the caches were cleared).
                guard let recipe = try services.edits.recipe(id: id, version: ev) else { throw HTTPError(.notFound) }
                let edits = services.edits
                try await renderLimiter.run {
                    try await blocking { try edits.ensureRendered(id: id, version: ev, recipe: recipe, source: source, formats: [format]) }
                }
                url = store.url(id: id, kind: kind, editVersion: ev, format: format)
            } else {
                url = try await renderLimiter.run {
                    try await blocking { try store.ensure(id: id, source: source, kind: kind, editVersion: ev, format: format) }
                }
            }
        }
        let body = try await fileIO.loadFile(path: url.path, context: ctx)
        return Response(status: .ok, headers: [
            .contentType: format.mimeType,
            .cacheControl: "public, max-age=31536000, immutable",
        ], body: body)
    }

    func settingsResponse() throws -> Response {
        let s = services.settings
        let dbBytes = ["", "-wal"].reduce(Int64(0)) { sum, suffix in
            let attrs = try? FileManager.default.attributesOfItem(atPath: services.paths.databaseURL.path + suffix)
            return sum + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return try json(SettingsResponse(libraryPath: try s.get(.libraryPath), uploadsPath: try s.get(.uploadsPath), ownerLogin: try s.get(.ownerLogin),
                                         dataDir: services.paths.dataDir.path, cacheBytes: services.derivatives().sizeOnDisk(),
                                         databaseBytes: dbBytes, dataLocationMissing: services.dataLocationMissing,
                                         facesEnabled: try s.get(.facesEnabled),
                                         faceModelInstalled: FaceAnalyzer.modelInstalled(dataDir: services.paths.dataDir),
                                         faceModelPath: FaceAnalyzer.modelURL(dataDir: services.paths.dataDir).path,
                                         mapStyleURL: try s.get(.mapStyleURL), defaultMapStyleURL: Self.defaultMapStyle))
    }
}
