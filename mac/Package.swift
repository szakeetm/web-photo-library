// swift-tools-version:6.0
import PackageDescription

// Menu bar helper that runs the photo server and opens the web app. Assembled into
// PhotoServer.app by scripts/build-app.sh.
let package = Package(
    name: "PhotoServerApp",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "PhotoServerApp"),
    ]
)
