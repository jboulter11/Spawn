// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "Spawn",
    targets: [Target(name: "SpawnDemo", dependencies: ["Spawn"])]
)
