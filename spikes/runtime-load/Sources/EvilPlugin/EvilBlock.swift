// Harmless proofs of what a loaded block can do. Every file it touches is in
// $SPIKE_TMP, which the run script creates under .build/.
// EVIL_MODE: read | swizzle | crash | hang
import BlockContract
import Foundation
import ObjectiveC
import SwiftUI

@MainActor
final class EvilBlock: PluginBlock {
    let id = "evil"
    let mode = ProcessInfo.processInfo.environment["EVIL_MODE"] ?? "read"
    var title: String { "Evil(\(mode))" }
    var info: BlockInfo { BlockInfo(summary: "Misbehaviour proofs", symbol: "ant") }

    func activate(_ context: any BlockContext) {
        let tmp = ProcessInfo.processInfo.environment["SPIKE_TMP"] ?? "/nonexistent"
        switch mode {
        case "read":
            let secret = (try? String(contentsOfFile: tmp + "/host-secret.txt", encoding: .utf8)) ?? "<unreadable>"
            try? ("copied by plugin: " + secret).write(toFile: tmp + "/exfil.txt", atomically: true, encoding: .utf8)
            context.log("read a host-readable file: \(secret.trimmingCharacters(in: .whitespacesAndNewlines))")
        case "swizzle":
            if let cls = NSClassFromString("TNHostLicense"),
               let method = class_getInstanceMethod(cls, NSSelectorFromString("isPro")) {
                let replacement: @convention(block) (AnyObject) -> Bool = { _ in true }
                method_setImplementation(method, imp_implementationWithBlock(replacement))
                context.log("replaced TNHostLicense.isPro in the host")
            } else {
                context.log("host class not found")
            }
        case "crash":
            fatalError("evil block crashed on purpose")
        case "hang":
            Thread.sleep(forTimeInterval: 3)
            context.log("returned after blocking the main thread for 3 s")
        default:
            break
        }
        context.present(Presentation(size: CGSize(width: 120, height: 30)) { Text("evil") })
    }

    func handle(_ input: NotchInput) -> String { "ignored" }
}

@_cdecl("topnotch_block_entry")
public func topnotchBlockEntry() -> UnsafeMutableRawPointer {
    MainActor.assumeIsolated {
        Unmanaged.passRetained(EvilBlock() as AnyObject).toOpaque()
    }
}

@_cdecl("topnotch_block_contract_version")
public func topnotchBlockContractVersion() -> Int { blockContractVersion }
