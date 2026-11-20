// swift-tools-version: 6.2
import PackageDescription

// The shelf block, bundled inside the app. It runs as its own process and
// talks to the app over the wire protocol in ../../Packages/BlockKit.
// The app's "Build bundled blocks" phase builds it and packages it with
// manifest.json into Contents/Resources/Blocks/Shelf.topblock.
let package = Package(
    name: "Shelf",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Shelf", targets: ["Shelf"]),
    ],
    dependencies: [
        .package(path: "../../Packages/BlockKit"),
    ],
    targets: [
        .executableTarget(name: "Shelf", dependencies: [.product(name: "BlockKit", package: "BlockKit")]),
        .testTarget(name: "ShelfTests", dependencies: [
            "Shelf",
            .product(name: "BlockKit", package: "BlockKit"),
            .product(name: "BlockKitTesting", package: "BlockKit"),
        ]),
    ]
)
