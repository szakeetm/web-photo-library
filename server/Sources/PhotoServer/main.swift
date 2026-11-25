import Foundation
import PhotoAPI
import PhotoCore

let env = ProcessInfo.processInfo.environment
let port = env["PORT"].flatMap(Int.init) ?? 8787
let webRoot = env["WEB_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../web/build").standardizedFileURL
let services = try Services(paths: .resolve(), restart: {
    // Re-exec ourselves so the database is reopened at its new location.
    // Don't leak the listening socket (or the old database files) into the new process.
    for fd in 3..<getdtablesize() { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    let args = CommandLine.arguments
    let cArgs = args.map { strdup($0) } + [nil]
    execv(Bundle.main.executablePath ?? args[0], cArgs)
    exit(75)
})
print("PhotoServer \(serverVersion) [\(BuildInfo.current.label)] on http://127.0.0.1:\(port) — data \(services.paths.dataDir.path), web \(webRoot.path)")
let app = buildApplication(services: services, webRoot: webRoot, port: port)
try await app.runService()
