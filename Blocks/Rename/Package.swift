// swift-tools-version: 6.2
import PackageDescription

// The screenshot rename block, bundled inside the app. It runs as its own
// process and talks to the app over the wire protocol in ../../Packages/BlockKit.
// The app's "Build bundled blocks" phase builds it and packages it with
// manifest.json into Contents/Resources/Blocks/Rename.topblock.
let package = Package(
    name: "Rename",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Rename", targets: ["Rename"]),
    ],
    dependencies: [
        .package(path: "../../Packages/BlockKit"),
    ],
    targets: [
        .executableTarget(name: "Rename", dependencies: [.product(name: "BlockKit", package: "BlockKit")]),
        .testTarget(name: "RenameTests", dependencies: [
            "Rename",
            .product(name: "BlockKit", package: "BlockKit"),
            .product(name: "BlockKitTesting", package: "BlockKit"),
        ]),
    ]
)
