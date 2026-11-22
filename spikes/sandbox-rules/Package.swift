// swift-tools-version: 6.0
// Throwaway spike: what the block sandbox can express (Phase 8, Task 1).
import PackageDescription

let package = Package(
    name: "SandboxRules",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "sbspike", path: "Sources/sbspike"),
    ]
)
