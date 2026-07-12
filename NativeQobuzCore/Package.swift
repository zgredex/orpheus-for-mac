// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "NativeQobuzCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NativeQobuzCore", targets: ["NativeQobuzCore"])
    ],
    targets: [
        .target(name: "NativeQobuzCore"),
        .testTarget(
            name: "NativeQobuzCoreTests",
            dependencies: ["NativeQobuzCore"]
        )
    ]
)
