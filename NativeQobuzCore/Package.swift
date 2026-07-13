// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "NativeQobuzCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NativeQobuzCore", targets: ["NativeQobuzCore"]),
        .executable(name: "native-qobuz-audit", targets: ["NativeQobuzAudit"]),
        .executable(name: "native-qobuz-acceptance", targets: ["NativeQobuzAcceptance"])
    ],
    targets: [
        .target(
            name: "NativeQobuzCore",
            resources: [.copy("Resources/MediaValidator")]
        ),
        .executableTarget(
            name: "NativeQobuzAudit",
            dependencies: ["NativeQobuzCore"]
        ),
        .executableTarget(
            name: "NativeQobuzAcceptance",
            dependencies: ["NativeQobuzCore"]
        ),
        .testTarget(
            name: "NativeQobuzCoreTests",
            dependencies: ["NativeQobuzCore"]
        )
    ]
)
