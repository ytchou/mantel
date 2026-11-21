// swift-tools-version: 6.2
import PackageDescription

// Every module is declared here. Parallel work stays inside one module
// directory and does not edit this file; adding a module is its own change.
// No block is linked into the app: every block runs in its own process, over
// the wire protocol in ../BlockKit, and BlockHost runs its stand-in.
let package = Package(
    name: "NotchKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "NotchKit",
            targets: ["NotchCore", "NotchShell", "EventSources", "PlatformServices", "BlockHost"]
        )
    ],
    dependencies: [
        .package(path: "../BlockKit"),
        // The bundled blocks, for BothBlocksTests only: no product above
        // depends on them, so none is linked into the app.
        .package(path: "../../Blocks/NowPlaying"),
        .package(path: "../../Blocks/Rename"),
        .package(path: "../../Blocks/Shelf"),
    ],
    targets: [
        .target(name: "NotchCore"),
        .target(name: "NotchShell", dependencies: ["NotchCore"]),
        .target(name: "EventSources", dependencies: ["NotchCore"]),
        .target(name: "PlatformServices", dependencies: ["NotchCore"]),
        .target(name: "BlockHost", dependencies: ["NotchCore", .product(name: "BlockWire", package: "BlockKit")]),
        // A tiny block process for BlockHostTests. Not part of the product.
        .executableTarget(name: "FixtureBlock", dependencies: [.product(name: "BlockKit", package: "BlockKit")]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"]),
        .testTarget(name: "NotchShellTests", dependencies: ["NotchShell"]),
        .testTarget(name: "EventSourcesTests", dependencies: ["EventSources"]),
        .testTarget(name: "PlatformServicesTests", dependencies: ["PlatformServices"]),
        .testTarget(name: "BlockHostTests", dependencies: [
            "BlockHost", "NotchCore", .product(name: "BlockWire", package: "BlockKit"),
        ]),
        // All blocks in one runtime: what happens when they want the notch at once.
        // Each runs as a stand-in, as in the app, over an in-memory connection
        // to the real block's code, run in this process by the BlockKit runner.
        .testTarget(name: "BothBlocksTests", dependencies: [
            "NotchCore", "BlockHost",
            .product(name: "BlockWire", package: "BlockKit"),
            .product(name: "BlockKit", package: "BlockKit"),
            .product(name: "NowPlayingCore", package: "NowPlaying"),
            .product(name: "RenameCore", package: "Rename"),
            .product(name: "ShelfCore", package: "Shelf"),
        ]),
    ]
)
