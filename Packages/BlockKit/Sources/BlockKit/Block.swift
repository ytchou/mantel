@_exported import BlockWire
import Foundation

/// A block that runs in its own process.
///
/// ```swift
/// @main struct Hello: Block {
///     func start(_ ctx: Context) {
///         ctx.on(.pointerHover) { event in ... }
///     }
/// }
/// ```
///
/// Everything runs on the main thread. A block that blocks the main thread
/// for 3 seconds stops answering the app's heartbeat and is restarted.
@MainActor
public protocol Block: Sendable {
    init()
    /// The block's id. By default, the `id` in the `manifest.json` next to
    /// the executable.
    var id: String { get }
    /// The block's version. By default, the `version` in that manifest.
    var version: String { get }
    /// The contract version the block says in `hello`. By default, the
    /// `contract` in that manifest, or `Contract.current` without one. A
    /// block that says 1 gets no version 2 message from the app.
    var contract: Int { get }
    /// Called once, after the app has answered `hello`. Register handlers
    /// here; settings and the data folder are ready.
    func start(_ ctx: Context)
}

public extension Block {
    var id: String { PackagedManifest.current?.id ?? ProcessInfo.processInfo.processName }
    var version: String { PackagedManifest.current?.version ?? "0" }
    var contract: Int { PackagedManifest.current?.contract ?? Contract.current }

    /// Runs the block on fd 3 until the app sends `quit` or closes the
    /// socket, then exits.
    static func main() async {
        let runner = Runner(block: Self(), transport: SocketTransport(fd: 3))
        await runner.run()
        exit(0)
    }
}

/// The manifest of the package this executable runs from, if any.
enum PackagedManifest {
    static let current: Manifest? = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        // A bundle keeps it in Contents/Resources, the executable in
        // Contents/MacOS. A version 1 package keeps it at the package root,
        // the executable perhaps in a subfolder named by the manifest.
        var folder = executable.deletingLastPathComponent()
        for _ in 0..<3 {
            for file in [folder.appendingPathComponent("Resources/manifest.json"), folder.appendingPathComponent("manifest.json")] {
                if let data = try? Data(contentsOf: file), let manifest = try? Manifest.decode(data) {
                    return manifest
                }
            }
            folder.deleteLastPathComponent()
        }
        return nil
    }()
}
