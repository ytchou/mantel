// swift-tools-version: 6.2
// Throwaway spike: screenshot detection, OCR, on-device naming, rename with date preservation.
import PackageDescription

let package = Package(
    name: "NameSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "NameSpike",
            path: "Sources/NameSpike"
        )
    ],
    swiftLanguageModes: [.v5]
)
