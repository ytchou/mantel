// swift-tools-version: 6.2
import PackageDescription

// Every module is declared here. Parallel work stays inside one module
// directory and does not edit this file; adding a module is its own change.
// No block is linked into the app or into any target here: every block runs
// in its own process, over the wire protocol in ../BlockKit, and BlockHost
// runs its stand-in. The collision tests that run real blocks together live
// with the blocks, in the topnotch-blocks repository (tests/collisions).
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
    ]
)
