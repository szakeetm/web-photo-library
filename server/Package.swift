// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhotoServer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PhotoServer", targets: ["PhotoServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "PhotoCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Places/geonames.deflate")]
        ),
        .target(
            name: "PhotoAPI",
            dependencies: [
                "PhotoCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        .executableTarget(name: "PhotoServer", dependencies: ["PhotoAPI"]),
        .testTarget(name: "PhotoCoreTests", dependencies: ["PhotoCore"]),
        .testTarget(
            name: "PhotoAPITests",
            dependencies: [
                "PhotoAPI",
                "PhotoCore",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
