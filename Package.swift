// swift-tools-version: 6.2
import PackageDescription

// The kit, for block authors who add it by URL:
//   .package(url: "https://github.com/ytchou/mantel.git", from: "0.1.0")
//   .product(name: "BlockKit", package: "mantel")
// The URL package's identity is `mantel` (the repository name), so authors
// pass "mantel" as `package:`.
//
// Why two manifests: a package added by local path is identified by its folder
// name, which differs per worktree and checkout, so the app and NotchKit keep
// using Packages/BlockKit/Package.swift by path, and authors need a URL. This
// manifest declares the same three library targets from the same sources.
// Both manifests must change together: targets, dependencies and settings.
// No example, no tests here: those stay in Packages/BlockKit.
let package = Package(
    name: "Mantel",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BlockWire", targets: ["BlockWire"]),
        .library(name: "BlockKit", targets: ["BlockKit"]),
        .library(name: "BlockKitTesting", targets: ["BlockKitTesting"]),
    ],
    targets: [
        .target(name: "BlockWire", path: "Packages/BlockKit/Sources/BlockWire"),
        .target(name: "BlockKit", dependencies: ["BlockWire"], path: "Packages/BlockKit/Sources/BlockKit"),
        .target(name: "BlockKitTesting", dependencies: ["BlockKit"], path: "Packages/BlockKit/Sources/BlockKitTesting"),
    ]
)
