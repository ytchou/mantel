// Host that links the REAL NotchCore (built by run.sh as a dynamic library
// with library evolution) and loads the real DemoBlock from a folder.
// Drives it through the real NotchRuntime: register, hover, click, drop.
// Usage: tn-spike-realhost <plugins-folder>
import AppKit
import Foundation
import NotchCore
import SwiftUI

let clock = ContinuousClock()

func ms(_ d: Duration) -> String {
    String(format: "%.2f", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}

func out(_ s: String) {
    print(s)
    fflush(stdout)
}

@MainActor
func render(_ content: NotchContent, _ label: String) {
    let t = clock.now
    let renderer = ImageRenderer(content: content.makeView().frame(width: content.size.width, height: content.size.height))
    renderer.scale = 2
    if let image = renderer.cgImage {
        out("REAL \(label) rendered-view \(image.width)x\(image.height)px render-ms=\(ms(clock.now - t))")
        if let dir = ProcessInfo.processInfo.environment["SPIKE_TMP"],
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/demoblock.png"))
        }
    } else {
        out("REAL \(label) render returned nil")
    }
}

@MainActor
func run() -> Int32 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1])
    let runtime = NotchRuntime()
    let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    for url in items where url.pathExtension == "topblock" {
        guard let exe = Bundle(url: url)?.executableURL else { continue }
        let t0 = clock.now
        guard let handle = dlopen(exe.path, RTLD_NOW | RTLD_LOCAL) else {
            out("LOAD_FAIL dlopen: \(String(cString: dlerror()))")
            return 3
        }
        let t1 = clock.now
        guard let sym = dlsym(handle, "topnotch_block_entry") else {
            out("LOAD_FAIL dlsym: \(String(cString: dlerror()))")
            return 3
        }
        let entry = unsafeBitCast(sym, to: (@convention(c) () -> UInt).self)
        let object = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(bitPattern: entry())!).takeRetainedValue()
        guard let block = object as? any NotchBlock else {
            out("LOAD_FAIL \(type(of: object)) is not a NotchBlock")
            return 3
        }
        runtime.register(block)
        out("REAL loaded \(url.lastPathComponent) id=\(block.id) title=\(block.title) symbol=\(block.info.symbol) dlopen-ms=\(ms(t1 - t0)) total-ms=\(ms(clock.now - t0))")
    }

    runtime.pointerHoverChanged(isInside: true)
    guard let owner = runtime.state.owner, let presentation = runtime.state.presentation,
          let content = presentation.expanded ?? presentation.peek else {
        out("REAL no presentation after hover")
        return 4
    }
    out("REAL after hover: owner=\(owner) level=\(String(describing: runtime.state.level!)) accepts=\(presentation.accepts.count) kinds")
    runtime.send(.click)
    runtime.send(.click)
    runtime.send(.drop([.file(URL(fileURLWithPath: "/tmp/example.png"))]))
    render(content, "after 2 clicks + drop")
    out("REAL done")
    return 0
}

let code = MainActor.assumeIsolated { run() }
exit(code)
