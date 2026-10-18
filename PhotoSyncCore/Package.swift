// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoSyncCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotoSyncCore", targets: ["PhotoSyncCore"]),
    ],
    targets: [
        .target(name: "PhotoSyncCore"),
        .testTarget(name: "PhotoSyncCoreTests", dependencies: ["PhotoSyncCore"]),
    ]
)
