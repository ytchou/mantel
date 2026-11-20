// swift-tools-version: 6.2
import PackageDescription

// The now-playing block, bundled inside the app. It runs as its own process
// and talks to the app over the wire protocol in ../../Packages/BlockKit.
// The app's "Build bundled blocks" phase builds it and packages it with
// manifest.json into Contents/Resources/Blocks/NowPlaying.topblock.
let package = Package(
    name: "NowPlaying",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NowPlaying", targets: ["NowPlaying"]),
        // The block's code, for this package's tests and for the collision
        // tests in ../../Packages/NotchKit (BothBlocksTests), which run it
        // in process. Never linked into the app.
        .library(name: "NowPlayingCore", targets: ["NowPlayingCore"]),
    ],
    dependencies: [
        .package(path: "../../Packages/BlockKit"),
    ],
    targets: [
        // All of the block but its entry point.
        .target(name: "NowPlayingCore", dependencies: [.product(name: "BlockKit", package: "BlockKit")]),
        // The entry point only: main.swift. The bundled-blocks build phase
        // builds this product by name.
        .executableTarget(name: "NowPlaying", dependencies: [
            "NowPlayingCore",
            .product(name: "BlockKit", package: "BlockKit"),
        ]),
        .testTarget(name: "NowPlayingTests", dependencies: [
            "NowPlayingCore",
            .product(name: "BlockKit", package: "BlockKit"),
            .product(name: "BlockKitTesting", package: "BlockKit"),
        ]),
    ]
)
