import Foundation
import PhotoAPI
import PhotoCore

let env = ProcessInfo.processInfo.environment
let port = env["PORT"].flatMap(Int.init) ?? 8787
let webRoot = env["WEB_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../web/build").standardizedFileURL
let services = try Services(paths: .standard())
print("PhotoServer \(serverVersion) on http://127.0.0.1:\(port) — data \(services.paths.dataDir.path), web \(webRoot.path)")
let app = buildApplication(services: services, webRoot: webRoot, port: port)
try await app.runService()
