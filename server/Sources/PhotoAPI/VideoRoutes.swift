import Foundation
import Hummingbird
import HTTPTypes
import PhotoCore

/// Video playback (originals or converted previews), Live Photo motion clips and "Convert all".
extension APIRoutes {
    struct StatusBody: Encodable {
        let status: VideoStatus
        /// A converted copy exists (the original needed one), downloadable from `/video/download`.
        var converted: Bool? = nil
    }

    /// `/video` and `/motion` URLs are unversioned (the file behind them can change, e.g. a re-converted
    /// preview), so they are cached briefly and revalidated by ETag.
    static let videoCache = "private, max-age=3600"
    static let originalCache = "private, max-age=3600"

    func registerVideoRoutes(on api: RouterGroup<BasicRequestContext>) {
        let videos = services.videos

        api.get("assets/:id/video") { req, ctx in
            guard let id = validId(ctx),
                  let asset = try services.catalog.record(id: id), asset.kind == "video"
            else { throw HTTPError(.notFound) }
            // the original's type from the catalog: the file is only fetched when it's served
            let ext = (try services.catalog.originalName(id: id)).map { ($0 as NSString).pathExtension }
            let playable = ext.map { VideoProbe.safariPlayable(codec: asset.videoCodec, ext: $0) } ?? false
            // ?original=1 (local mode): the original whenever browsers can play it, whatever its size
            let wantsOriginal = req.uri.queryParameters.get("original") == "1"
            if asset.servePlan != "preview" || (wantsOriginal && playable) {
                guard let original = try await services.catalog.originals.file(id) else { throw HTTPError(.notFound) }
                return try await serveOriginal(original, req, ctx)
            }
            let preview = videos.previewURL(id: id)
            if FileManager.default.fileExists(atPath: preview.path) { return try await servePreview(preview, req, ctx) }
            let status = videos.request(id: id)
            switch status {
            case .ready:
                return try await servePreview(preview, req, ctx)
            case .queued, .converting:
                return try json(StatusBody(status: status), status: .accepted)
            case .unavailable, .failed:
                guard ext != nil else { throw HTTPError(.notFound) }
                guard playable else { return errorResponse(.conflict, "unplayable") }
                guard let original = try await services.catalog.originals.file(id) else { throw HTTPError(.notFound) }
                return try await serveOriginal(original, req, ctx)
            }
        }

        api.get("assets/:id/video/status") { _, ctx in
            guard let id = validId(ctx), try services.catalog.kind(id: id) == "video" else { throw HTTPError(.notFound) }
            let plan = try services.catalog.record(id: id)?.servePlan
            let converted = plan == "preview" && FileManager.default.fileExists(atPath: videos.previewURL(id: id).path)
            return try json(StatusBody(status: videos.status(id: id), converted: converted))
        }

        // The converted copy as a download (only for videos that needed one).
        api.get("assets/:id/video/download") { req, ctx in
            guard let id = validId(ctx),
                  let asset = try services.catalog.record(id: id), asset.kind == "video", asset.servePlan == "preview"
            else { throw HTTPError(.notFound) }
            let preview = videos.previewURL(id: id)
            guard FileManager.default.fileExists(atPath: preview.path) else { throw HTTPError(.notFound) }
            let base = (try services.catalog.originalName(id: id)).map { ($0 as NSString).deletingPathExtension } ?? id
            return try await fileResponse(path: preview.path, contentType: "video/mp4", request: req, context: ctx, extraHeaders: [
                .contentDisposition: "attachment; filename*=UTF-8''\(percentEncoded(base + "-converted.mp4"))",
                .cacheControl: Self.videoCache,
            ])
        }

        api.get("assets/:id/motion") { req, ctx in
            guard let id = validId(ctx),
                  let motion = try services.catalog.motion(id: id)
            else { throw HTTPError(.notFound) }
            // Clips Safari plays (H.264/HEVC in MOV/MP4) are served as they are and never converted.
            if VideoProbe.safariPlayable(codec: motion.codec, ext: (motion.relPath as NSString).pathExtension) {
                guard let url = try await services.catalog.originals.motionFile(id) else { throw HTTPError(.notFound) }
                return try await serveOriginal(url, req, ctx)
            }
            let preview = videos.motionPreviewURL(id: id)
            if FileManager.default.fileExists(atPath: preview.path) { return try await servePreview(preview, req, ctx) }
            let status = videos.request(id: id, motion: true)
            switch status {
            case .ready: return try await servePreview(preview, req, ctx)
            case .queued, .converting: return try json(StatusBody(status: status), status: .accepted)
            case .unavailable, .failed: return errorResponse(.conflict, "unplayable")
            }
        }

        // A Live Photo's motion clip as a file: the original, named like the still (IMG_1234.HEIC →
        // IMG_1234.MOV) so the pair stays recognisable; Photos pairs them by their content identifier.
        api.get("assets/:id/motion/download") { req, ctx in
            guard let id = validId(ctx), let still = try services.catalog.originalName(id: id),
                  let url = try await services.catalog.originals.motionFile(id)
            else { throw HTTPError(.notFound) }
            let name = (still as NSString).deletingPathExtension + "." + url.pathExtension.uppercased()
            return try await fileResponse(path: url.path, contentType: contentType(forExtension: url.pathExtension), request: req,
                                          context: ctx, extraHeaders: [
                                              .contentDisposition: "attachment; filename*=UTF-8''\(percentEncoded(name))",
                                              .cacheControl: Self.originalCache,
                                          ])
        }

        // Trims (database only; playing and exports apply them)
        let trims = VideoTrimService(db: services.db)
        struct TrimBody: Decodable { let start: Double; let end: Double }
        struct TrimmedAsset: Encodable { let asset: CatalogAsset }
        @Sendable func trimCall(_ work: @escaping @Sendable () async throws -> Response) async throws -> Response {
            do { return try await work() } catch let e as TrimError {
                return errorResponse(e.description.hasPrefix("Trimming failed") ? .internalServerError : .badRequest, e.description)
            }
        }
        api.put("assets/:id/trim") { req, ctx in
            guard let id = validId(ctx), let body = try? await req.decode(as: TrimBody.self, context: ctx) else { throw HTTPError(.badRequest) }
            return try await trimCall {
                try await blocking { try trims.set(id: id, start: body.start, end: body.end) }
                guard let a = try services.catalog.catalogAsset(id: id) else { throw HTTPError(.notFound) }
                return try json(TrimmedAsset(asset: a))
            }
        }
        api.delete("assets/:id/trim") { _, ctx in
            guard let id = validId(ctx) else { throw HTTPError(.notFound) }
            try await blocking { try trims.revert(id: id) }
            guard let a = try services.catalog.catalogAsset(id: id) else { throw HTTPError(.notFound) }
            return try json(TrimmedAsset(asset: a))
        }
        // Save as New: a losslessly trimmed copy in the uploads folder (edited-uploads/), as a new video.
        api.post("assets/:id/trim/copy") { req, ctx in
            guard let id = validId(ctx), let body = try? await req.decode(as: TrimBody.self, context: ctx) else { throw HTTPError(.badRequest) }
            guard let rootPath = try services.settings.get(.uploadsPath) else {
                return errorResponse(.conflict, UploadError.notConfigured.description)
            }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            return try await trimCall {
                let (start, end) = try trims.validated(id: id, start: body.start, end: body.end)
                guard let source = try await services.catalog.originals.file(id), let record = try services.catalog.record(id: id) else {
                    throw HTTPError(.notFound)
                }
                let incoming = root.appendingPathComponent(".incoming", isDirectory: true)
                try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
                let ext = source.pathExtension
                let temp = incoming.appendingPathComponent(UUID().uuidString + "." + ext)
                defer { try? FileManager.default.removeItem(at: temp) }
                try await VideoCutter.cut(source: source, start: start, end: end, to: temp,
                                          creationDate: record.takenAt.addingTimeInterval(start), tzOffset: record.tzOffset,
                                          ffmpeg: services.ffmpeg)
                let name = source.deletingPathExtension().lastPathComponent + " (trimmed)." + ext
                let asset = try await blocking {
                    let rel = try UploadPlacer.place(temp: temp, uploadsRoot: root, source: .edited, name: name,
                                                     takenAt: record.takenAt, tzOffset: record.tzOffset)
                    let id = try LibraryScanner(db: services.db, root: root, rootName: Roots.uploads).indexFile(relPath: rel)
                    guard let a = try services.catalog.catalogAsset(id: id) else { throw HTTPError(.internalServerError) }
                    return a
                }
                return try json(TrimmedAsset(asset: asset))
            }
        }
        // The trim editor's filmstrip: `n` frames side by side in one JPEG (cached).
        api.get("assets/:id/frames") { req, ctx in
            guard let id = validId(ctx), let record = try services.catalog.record(id: id), record.kind == "video",
                  let duration = record.duration else { throw HTTPError(.notFound) }
            let n = min(30, max(2, req.uri.queryParameters.get("n", as: Int.self) ?? 12))
            let dir = services.paths.cacheDir.appendingPathComponent("frames", isDirectory: true)
            let file = dir.appendingPathComponent("\(id)-\(n).jpg")
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                guard let source = try await services.catalog.originals.file(id) else { throw HTTPError(.notFound) }
                let data: Data
                do { data = try await VideoCutter.filmstrip(source: source, duration: duration, count: n) } catch {
                    // formats AVFoundation can't read: the converted preview, if there is one
                    let preview = videos.previewURL(id: id)
                    guard FileManager.default.fileExists(atPath: preview.path) else { throw HTTPError(.notFound) }
                    data = try await VideoCutter.filmstrip(source: preview, duration: duration, count: n)
                }
                try data.write(to: file, options: .atomic)
            }
            return try await fileResponse(path: file.path, contentType: "image/jpeg", request: req, context: ctx,
                                          extraHeaders: [.cacheControl: "private, max-age=86400"])
        }

        api.get("videos") { _, _ in try json(try await blocking { videos.allState() }) }
        api.post("videos/convert-all") { _, _ in
            try json(try await blocking { videos.startAll(); return videos.allState() })
        }
        api.post("videos/pause") { _, _ in
            try json(try await blocking { videos.pause(); return videos.allState() })
        }
    }

    func serveOriginal(_ url: URL, _ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let type = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        return try await fileResponse(path: url.path, contentType: type, request: req, context: ctx,
                                      extraHeaders: [.cacheControl: Self.videoCache], etag: true)
    }

    func servePreview(_ url: URL, _ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        try await fileResponse(path: url.path, contentType: "video/mp4", request: req, context: ctx,
                               extraHeaders: [.cacheControl: Self.videoCache], etag: true)
    }
}
