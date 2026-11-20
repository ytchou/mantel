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
    ],
    dependencies: [
        .package(path: "../../Packages/BlockKit"),
    ],
    targets: [
        .executableTarget(name: "NowPlaying", dependencies: [.product(name: "BlockKit", package: "BlockKit")]),
        .testTarget(name: "NowPlayingTests", dependencies: [
            "NowPlaying",
            .product(name: "BlockKit", package: "BlockKit"),
            .product(name: "BlockKitTesting", package: "BlockKit"),
        ]),
    ]
)
