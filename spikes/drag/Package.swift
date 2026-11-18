// swift-tools-version: 6.2
// Throwaway spike: drag-start detection without Accessibility, drop shelf, drag out.
import PackageDescription

let package = Package(
    name: "DragSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "DragSpike",
            path: "Sources/DragSpike"
        )
    ],
    swiftLanguageModes: [.v5]
)
