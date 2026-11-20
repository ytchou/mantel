// swift-tools-version: 6.2
import PackageDescription

// Every module is declared here. Parallel work stays inside one module
// directory and does not edit this file; adding a module is its own change.
// Rule: blocks depend on NotchCore only. They never import NotchShell or each other.
// BlockHost runs blocks that live outside the app, in their own process, over
// the wire protocol in ../BlockKit.
let package = Package(
    name: "NotchKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "NotchKit",
            targets: ["NotchCore", "NotchShell", "EventSources", "DemoBlock", "ShelfBlock", "RenameBlock", "NowPlayingBlock", "PlatformServices", "BlockHost"]
        )
    ],
    dependencies: [
        .package(path: "../BlockKit"),
    ],
    targets: [
        .target(name: "NotchCore"),
        .target(name: "NotchShell", dependencies: ["NotchCore"]),
        .target(name: "EventSources", dependencies: ["NotchCore"]),
        .target(name: "DemoBlock", dependencies: ["NotchCore"]),
        .target(name: "ShelfBlock", dependencies: ["NotchCore"]),
        .target(name: "RenameBlock", dependencies: ["NotchCore"]),
        .target(name: "NowPlayingBlock", dependencies: ["NotchCore"]),
        .target(name: "PlatformServices", dependencies: ["NotchCore"]),
        .target(name: "BlockHost", dependencies: ["NotchCore", .product(name: "BlockWire", package: "BlockKit")]),
        // A tiny block process for BlockHostTests. Not part of the product.
        .executableTarget(name: "FixtureBlock", dependencies: [.product(name: "BlockKit", package: "BlockKit")]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"]),
        .testTarget(name: "NotchShellTests", dependencies: ["NotchShell"]),
        .testTarget(name: "EventSourcesTests", dependencies: ["EventSources"]),
        .testTarget(name: "DemoBlockTests", dependencies: ["DemoBlock"]),
        .testTarget(name: "ShelfBlockTests", dependencies: ["ShelfBlock"]),
        .testTarget(name: "RenameBlockTests", dependencies: ["RenameBlock"]),
        .testTarget(name: "NowPlayingBlockTests", dependencies: ["NowPlayingBlock"]),
        .testTarget(name: "PlatformServicesTests", dependencies: ["PlatformServices"]),
        .testTarget(name: "BlockHostTests", dependencies: ["BlockHost", "NotchCore", .product(name: "BlockWire", package: "BlockKit")]),
        // All blocks in one runtime: what happens when they want the notch at once.
        .testTarget(name: "BothBlocksTests", dependencies: ["NotchCore", "ShelfBlock", "RenameBlock", "NowPlayingBlock"]),
    ]
)
