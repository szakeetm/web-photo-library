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
    ],
    targets: [
        .target(
            name: "PhotoCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "PhotoServer",
            dependencies: [
                "PhotoCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(name: "PhotoCoreTests", dependencies: ["PhotoCore"]),
        .testTarget(
            name: "PhotoServerTests",
            dependencies: [
                "PhotoServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
