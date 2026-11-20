// swift-tools-version: 6.2
// Throwaway spike: can a block run in its own process, get events from the
// host, and show its view inside the notch with input that still feels
// instant? Not imported by the app or NotchKit.

import PackageDescription

let package = Package(
    name: "SeparateProcessSpike",
    platforms: [.macOS(.v26)],
    targets: [
        // Private CAContext / CALayerHost declarations (option 3, private route).
        .target(name: "RemoteLayer", path: "Sources/RemoteLayer"),
        // Wire protocol, timing probes, stats, the shared test view.
        .target(name: "SpikeShared", path: "Sources/SpikeShared"),
        .executableTarget(name: "spike-host", dependencies: ["SpikeShared", "RemoteLayer"],
                          path: "Sources/spike-host"),
        .executableTarget(name: "spike-block", dependencies: ["SpikeShared", "RemoteLayer"],
                          path: "Sources/spike-block"),
    ],
    // Swift 5 mode: throwaway code, avoid strict-concurrency friction.
    swiftLanguageModes: [.v5]
)
