// swift-tools-version: 6.2
// Throwaway spike: can our own NSPanel sit over the notch, expand on hover,
// and never take keyboard focus? Not imported by the app or NotchKit.

import PackageDescription

let package = Package(
    name: "NotchSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "NotchSpike",
            path: "Sources/NotchSpike"
        )
    ],
    // Swift 5 mode: throwaway code, avoid strict-concurrency friction.
    swiftLanguageModes: [.v5]
)
