// swift-tools-version: 5.5

import PackageDescription

let package = Package(
    name: "Spawn",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(name: "Spawn", targets: ["Spawn"])
    ],
    dependencies: [
    ],
    targets: [
        .target(name: "Spawn"),
        .executableTarget(
            name: "SpawnDemo",
            dependencies: [
                "Spawn"
            ]
        )
    ]
)
