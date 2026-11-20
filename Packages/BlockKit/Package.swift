// swift-tools-version: 6.2
import PackageDescription

// The kit for blocks that run in their own process.
// BlockWire: the wire protocol (messages, view tree, manifest, framing).
// BlockKit: what a block author writes against. Both import Foundation only.
// BlockKitTesting: a fake app for a block's own tests.
// This package never depends on NotchKit.
let package = Package(
    name: "BlockKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BlockWire", targets: ["BlockWire"]),
        .library(name: "BlockKit", targets: ["BlockKit"]),
        .library(name: "BlockKitTesting", targets: ["BlockKitTesting"]),
        .executable(name: "HelloBlock", targets: ["HelloBlock"]),
    ],
    targets: [
        .target(name: "BlockWire"),
        .target(name: "BlockKit", dependencies: ["BlockWire"]),
        .target(name: "BlockKitTesting", dependencies: ["BlockKit"]),
        // The kit's example; package it with Scripts/package-block.sh.
        .executableTarget(name: "HelloBlock", dependencies: ["BlockKit"], path: "Examples/HelloBlock", exclude: ["manifest.json"]),
        .testTarget(name: "BlockWireTests", dependencies: ["BlockWire"], exclude: ["Fixtures"]),
        .testTarget(name: "BlockKitTests", dependencies: ["BlockKit", "BlockKitTesting"]),
    ]
)
