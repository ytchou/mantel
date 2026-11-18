import AppKit

// Line-buffer stdout so each log line arrives immediately when piped.
setvbuf(stdout, nil, _IOLBF, 0)

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let app = NSApplication.shared
// Accessory: no Dock icon, no menu bar of our own, never needs to be frontmost.
app.setActivationPolicy(.accessory)
// Global: NSApp.delegate is weak. Top-level code runs on the main thread.
let controller = MainActor.assumeIsolated { SpikeController(options: options) }
MainActor.assumeIsolated { app.delegate = controller }
app.run()
