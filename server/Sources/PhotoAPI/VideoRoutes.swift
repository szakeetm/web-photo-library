import Foundation
import Hummingbird
import HTTPTypes
import PhotoCore

/// Video playback (originals or converted previews), Live Photo motion clips and "Convert all".
extension APIRoutes {
    struct StatusBody: Encodable { let status: VideoStatus }

    static let previewCache = "private, max-age=31536000, immutable"
    static let originalCache = "private, max-age=3600"

    func registerVideoRoutes(on api: RouterGroup<BasicRequestContext>) {
        let videos = services.videos

        api.get("assets/:id/video") { req, ctx in
            guard let id = validId(ctx),
                  let asset = try services.catalog.record(id: id), asset.kind == "video"
            else { throw HTTPError(.notFound) }
            let original = try services.catalog.sourceURL(id: id)
            if asset.servePlan != "preview" {
                guard let original else { throw HTTPError(.notFound) }
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
                guard let original else { throw HTTPError(.notFound) }
                guard Self.safariPlayable(codec: asset.videoCodec, url: original) else {
                    return errorResponse(.conflict, "unplayable")
                }
                return try await serveOriginal(original, req, ctx)
            }
        }

        api.get("assets/:id/video/status") { _, ctx in
            guard let id = validId(ctx), try services.catalog.kind(id: id) == "video" else { throw HTTPError(.notFound) }
            return try json(StatusBody(status: videos.status(id: id)))
        }

        api.get("assets/:id/motion") { req, ctx in
            guard let id = validId(ctx),
                  let motion = try services.catalog.motion(id: id)
            else { throw HTTPError(.notFound) }
            // H.264/HEVC clips play as they are and are never converted.
            if Self.playableCodecs.contains(motion.codec ?? "") {
                guard let url = try services.catalog.motionURL(id: id) else { throw HTTPError(.notFound) }
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

        api.get("videos") { _, _ in try json(try await blocking { videos.allState() }) }
        api.post("videos/convert-all") { _, _ in
            try json(try await blocking { videos.startAll(); return videos.allState() })
        }
        api.post("videos/pause") { _, _ in
            try json(try await blocking { videos.pause(); return videos.allState() })
        }
    }

    static let playableCodecs: Set<String> = ["h264", "hevc"]
    static let playableExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// Safari plays H.264/HEVC in QuickTime/MP4 containers.
    static func safariPlayable(codec: String?, url: URL) -> Bool {
        playableCodecs.contains(codec ?? "") && playableExtensions.contains(url.pathExtension.lowercased())
    }

    func serveOriginal(_ url: URL, _ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let type = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        return try await fileResponse(path: url.path, contentType: type, request: req, context: ctx,
                                      extraHeaders: [.cacheControl: Self.originalCache])
    }

    func servePreview(_ url: URL, _ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        try await fileResponse(path: url.path, contentType: "video/mp4", request: req, context: ctx,
                               extraHeaders: [.cacheControl: Self.previewCache])
    }
}
