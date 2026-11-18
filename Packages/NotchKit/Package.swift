// swift-tools-version: 6.2
import PackageDescription

// All module names are declared here once, so parallel work never edits this file.
// Rule: blocks depend on NotchCore only. They never import NotchShell or each other.
let package = Package(
    name: "NotchKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "NotchKit",
            targets: ["NotchCore", "NotchShell", "EventSources", "DemoBlock", "ShelfBlock", "RenameBlock"]
        )
    ],
    targets: [
        .target(name: "NotchCore"),
        .target(name: "NotchShell", dependencies: ["NotchCore"]),
        .target(name: "EventSources", dependencies: ["NotchCore"]),
        .target(name: "DemoBlock", dependencies: ["NotchCore"]),
        .target(name: "ShelfBlock", dependencies: ["NotchCore"]),
        .target(name: "RenameBlock", dependencies: ["NotchCore"]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"]),
        .testTarget(name: "NotchShellTests", dependencies: ["NotchShell"]),
        .testTarget(name: "EventSourcesTests", dependencies: ["EventSources"]),
        .testTarget(name: "DemoBlockTests", dependencies: ["DemoBlock"]),
        .testTarget(name: "ShelfBlockTests", dependencies: ["ShelfBlock"]),
        .testTarget(name: "RenameBlockTests", dependencies: ["RenameBlock"]),
    ]
)
