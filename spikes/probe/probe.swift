// Throwaway probe used to check the other spikes without synthetic input events
// (this session has no permission to post mouse or key events).
//
//   swift probe.swift fullscreen
//       Puts its own window into full screen, then reports whether windows owned
//       by NotchSpike are still on screen, and leaves full screen again.
//   swift probe.swift drag <file|folder|text|link|promise> <cgX> <cgY>
//       Moves the cursor to (cgX, cgY) (top-left origin), then starts a real
//       drag session from its own window. No mouse button is held, so AppKit
//       ends the session at once and drops at the cursor position.
import AppKit
import UniformTypeIdentifiers

func log(_ s: String) { print("[probe] \(s)"); fflush(stdout) }

func notchSpikeWindows(_ owner: String) -> [String] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner }.map {
        let b = $0[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return "layer=\($0[kCGWindowLayer as String] ?? "?") bounds=(\(b["X"] ?? "?"),\(b["Y"] ?? "?"),\(b["Width"] ?? "?"),\(b["Height"] ?? "?"))"
    }
}

final class Source: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var ended: ((NSDragOperation) -> Void)?
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { [.copy, .generic, .link] }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        log("drag ended at \(p) operation=\(operation.rawValue)"); ended?(operation)
    }
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType t: String) -> String { "probe-promised.txt" }
    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try "promised by probe".write(to: url, atomically: true, encoding: .utf8); log("promise written to \(url.lastPathComponent)"); completionHandler(nil) }
        catch { completionHandler(error) }
    }
}

let args = CommandLine.arguments
let app = NSApplication.shared
guard args.count >= 2 else { print("usage: probe.swift fullscreen | drag <kind> <x> <y>"); exit(2) }

if args[1] == "fullscreen" {
    let owner = args.count > 2 ? args[2] : "NotchSpike"
    app.setActivationPolicy(.regular)
    let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                     styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    w.title = "probe"; w.collectionBehavior = [.fullScreenPrimary]
    w.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    log("before full screen: \(owner) windows on screen = \(notchSpikeWindows(owner))")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { w.toggleFullScreen(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { app.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
        log("frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") windowOnActiveSpace=\(w.isOnActiveSpace)")
        log("in full screen=\(w.styleMask.contains(.fullScreen)): \(owner) windows on screen = \(notchSpikeWindows(owner))")
        if args.count > 3 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", "400,0,712,220", args[3]]; try? p.run(); p.waitUntilExit()
        }
        w.toggleFullScreen(nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
        log("after leaving full screen: \(owner) windows on screen = \(notchSpikeWindows(owner))")
        exit(0)
    }
} else if args[1] == "drag", args.count >= 5, let x = Double(args[3]), let y = Double(args[4]) {
    app.setActivationPolicy(.accessory)
    let w = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 80, height: 40),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let v = Source(frame: NSRect(x: 0, y: 0, width: 80, height: 40)); w.contentView = v
    w.level = .floating; w.orderFrontRegardless()
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("probe-drag", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let file = tmp.appendingPathComponent("probe-file.txt"); try? "probe".write(to: file, atomically: true, encoding: .utf8)
    let folder = tmp.appendingPathComponent("probe-folder", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let writer: NSPasteboardWriting
    switch args[2] {
    case "file": writer = file as NSURL
    case "folder": writer = folder as NSURL
    case "text": writer = "Hello from the probe" as NSString
    case "link": writer = NSURL(string: "https://example.com/probe")!
    case "promise": writer = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: v)
    default: print("unknown kind"); exit(2)
    }
    let saved = CGEvent(source: nil)?.location ?? .zero
    v.ended = { _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { CGWarpMouseCursorPosition(saved); exit(0) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 40, height: 20), contents: NSImage(size: NSSize(width: 40, height: 20)))
        log("begin drag kind=\(args[2]) cursor -> (\(x), \(y))")
        _ = v.beginDraggingSession(with: [item], event: ev, source: v)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
        log("timeout: drag session did not end by itself"); CGWarpMouseCursorPosition(saved); exit(1)
    }
} else if args[1] == "hit", args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) {
    // Which window would receive a mouse event at this point (Cocoa coordinates, bottom-left origin)?
    let n = NSWindow.windowNumber(at: NSPoint(x: x, y: y), belowWindowWithWindowNumber: 0)
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let owner = list.first { ($0[kCGWindowNumber as String] as? Int) == n }?[kCGWindowOwnerName as String] as? String ?? "?"
    if args.count > 4 {  // optional: move the cursor there first, wait, and restore it afterwards
        let saved = CGEvent(source: nil)?.location ?? .zero
        CGWarpMouseCursorPosition(CGPoint(x: x, y: Double(NSScreen.main!.frame.height) - y))
        Thread.sleep(forTimeInterval: 0.8)
        let n2 = NSWindow.windowNumber(at: NSPoint(x: x, y: y), belowWindowWithWindowNumber: 0)
        let o2 = list.first { ($0[kCGWindowNumber as String] as? Int) == n2 }?[kCGWindowOwnerName as String] as? String ?? "?"
        log("hit (\(x), \(y)) cursor away: \(owner); cursor there: \(o2)")
        CGWarpMouseCursorPosition(saved)
    } else { log("hit (\(x), \(y)): \(owner)") }
    exit(0)
} else { print("bad arguments"); exit(2) }
app.run()
