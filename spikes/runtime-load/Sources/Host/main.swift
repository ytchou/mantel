// Throwaway spike host: finds *.topblock bundles in a folder, dlopens each,
// creates the block through a C entry point, calls it and renders its view.
// Usage: tn-spike-host <plugins-folder>
// Compiled with the same -D flags as the contract variant it links.
import AppKit
import BlockContract
import Foundation
import SwiftUI

let clock = ContinuousClock()
let mainStart = clock.now

func ms(_ d: Duration) -> String {
    String(format: "%.2f", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}

func out(_ s: String) {
    print(s)
    fflush(stdout)
}

/// Stands in for host-internal state a plugin should not be able to change.
@objc(TNHostLicense)
final class HostLicense: NSObject {
    @objc dynamic func isPro() -> Bool { false }
}

final class HostContext: BlockContext {
    var presented: Presentation?

    func present(_ presentation: Presentation) {
        presented = presentation
        out("HOST present priority=\(presentation.priority) size=\(Int(presentation.size.width))x\(Int(presentation.size.height))")
    }

    #if !V2_REMOVE
    func log(_ message: String) { out("HOST plugin-log \"\(message)\"") }
    #endif
}

@MainActor
func load(_ url: URL) -> Bool {
    let t0 = clock.now
    guard let bundle = Bundle(url: url), let exe = bundle.executableURL else {
        out("LOAD_FAIL not a bundle: \(url.lastPathComponent)")
        return false
    }
    let manifestID = bundle.infoDictionary?["TNBlockID"] as? String ?? "?"
    let manifestVersion = bundle.infoDictionary?["TNContractVersion"] as? Int ?? -1
    out("HOST manifest id=\(manifestID) contract=\(manifestVersion) (read before any plugin code runs)")

    let t1 = clock.now
    guard let handle = dlopen(exe.path, RTLD_NOW | RTLD_LOCAL) else {
        out("LOAD_FAIL dlopen: \(String(cString: dlerror()))")
        return false
    }
    let t2 = clock.now
    out("HOST dlopen-ms=\(ms(t2 - t1))")

    if let vsym = dlsym(handle, "topnotch_block_contract_version") {
        let version = unsafeBitCast(vsym, to: (@convention(c) () -> Int).self)
        out("HOST plugin-built-against-contract=\(version()) host-contract=\(blockContractVersion)")
    }
    guard let sym = dlsym(handle, "topnotch_block_entry") else {
        out("LOAD_FAIL dlsym: \(String(cString: dlerror()))")
        return false
    }
    let entry = unsafeBitCast(sym, to: (@convention(c) () -> UnsafeMutableRawPointer).self)
    let object = Unmanaged<AnyObject>.fromOpaque(entry()).takeRetainedValue()
    guard let block = object as? any PluginBlock else {
        out("LOAD_FAIL \(type(of: object)) does not conform to PluginBlock")
        return false
    }
    let t3 = clock.now
    out("HOST create-ms=\(ms(t3 - t2))")

    out("HOST block id=\(block.id) title=\(block.title)")
    let info = block.info
    #if V2_STRUCT
    out("HOST info summary=\(info.summary) symbol=\(info.symbol) trigger=\(info.trigger)")
    #else
    out("HOST info summary=\(info.summary) symbol=\(info.symbol)")
    #endif
    #if V2_ADDREQ
    out("HOST priorityHint=\(block.priorityHint) (default implementation returns 42)")
    #endif

    let context = HostContext()
    let ta = clock.now
    block.activate(context)
    out("HOST activate-ms=\(ms(clock.now - ta))")
    out("HOST handle(click) -> \(block.handle(.click))")
    out("HOST handle(drop) -> \(block.handle(.drop(["a.png", "b.txt"])))")
    #if V2_ENUM
    out("HOST handle(hover) -> \(block.handle(.hover(true)))")
    #endif

    if let p = context.presented {
        let tr = clock.now
        let renderer = ImageRenderer(content: p.makeView().frame(width: p.size.width, height: p.size.height))
        if let image = renderer.cgImage {
            out("HOST rendered-view \(image.width)x\(image.height)px render-ms=\(ms(clock.now - tr))")
        } else {
            out("HOST render returned nil")
        }
    } else {
        out("HOST no presentation")
    }
    out("HOST load-to-view-ms=\(ms(clock.now - t0))")
    return true
}

@MainActor
func runHost() -> Int32 {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        out("usage: tn-spike-host <plugins-folder>")
        return 64
    }
    let folder = URL(fileURLWithPath: args[1])
    let license = HostLicense()
    out("HOST license.isPro before load = \(license.isPro())")
    let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    let bundles = items.filter { $0.pathExtension == "topblock" }.sorted { $0.path < $1.path }
    out("HOST found \(bundles.count) plugin(s) in \(folder.lastPathComponent)")
    var failures = 0
    for url in bundles where !load(url) {
        failures += 1
    }
    out("HOST license.isPro after load = \(license.isPro())")
    out("HOST main-to-done-ms=\(ms(clock.now - mainStart))")
    return failures == 0 ? 0 : 3
}

let code = MainActor.assumeIsolated { runHost() }
exit(code)
