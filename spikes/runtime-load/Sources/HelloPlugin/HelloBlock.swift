// A well-behaved block built outside the host, against contract v1.
import BlockContract
import SwiftUI

@MainActor
final class HelloBlock: PluginBlock {
    let id = "hello"
    let title = "Hello"
    var info: BlockInfo { BlockInfo(summary: "Says hello", symbol: "hand.wave") }
    private var clicks = 0

    func activate(_ context: any BlockContext) {
        context.log("hello activated")
        context.present(Presentation(priority: 1, size: CGSize(width: 200, height: 40)) {
            Text("Hello from a plugin").frame(width: 200, height: 40)
        })
    }

    func handle(_ input: NotchInput) -> String {
        switch input {
        case .click:
            clicks += 1
            return "click #\(clicks)"
        case let .drop(items):
            return "drop \(items.count): \(items.joined(separator: ","))"
        @unknown default:
            return "unknown input (handled by @unknown default)"
        }
    }
}

/// Entry point the host looks up with dlsym. Returns a +1 retained object.
@_cdecl("topnotch_block_entry")
public func topnotchBlockEntry() -> UnsafeMutableRawPointer {
    MainActor.assumeIsolated {
        Unmanaged.passRetained(HelloBlock() as AnyObject).toOpaque()
    }
}

/// The contract version this plugin was compiled against (inlined at build).
@_cdecl("topnotch_block_contract_version")
public func topnotchBlockContractVersion() -> Int { blockContractVersion }
