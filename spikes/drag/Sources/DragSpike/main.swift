import AppKit
import ApplicationServices

// DragSpike: throwaway spike for the TopNotch shelf block.
//   swift run DragSpike                      normal mode, runs until Ctrl-C
//   swift run DragSpike --quit-after 120     normal mode, exits after 120 s
//   swift run DragSpike --selftest [4]       setup only, prints one JSON object, exits 0

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Arguments

enum Mode { case normal(quitAfter: Double?), selftest(seconds: Double) }

func parseMode(_ args: [String]) -> Mode {
    var i = 1
    var quitAfter: Double?
    while i < args.count {
        switch args[i] {
        case "--selftest":
            if i + 1 < args.count, let s = Double(args[i + 1]) { return .selftest(seconds: s) }
            return .selftest(seconds: 4)
        case "--quit-after":
            if i + 1 < args.count, let s = Double(args[i + 1]) { quitAfter = s; i += 1 }
            else { FileHandle.standardError.write("--quit-after needs <seconds>\n".data(using: .utf8)!); exit(2) }
        default:
            FileHandle.standardError.write("unknown argument \(args[i])\n".data(using: .utf8)!)
            exit(2)
        }
        i += 1
    }
    return .normal(quitAfter: quitAfter)
}

let mode = parseMode(CommandLine.arguments)

// MARK: Panel

/// Borderless, non-activating, never key. Clicks still reach views that accept first mouse.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let mode: Mode
    var panel: ShelfPanel!
    var shelf: ShelfView!
    let monitor = DragMonitor()
    var axTrusted = false

    init(mode: Mode) { self.mode = mode }

    func applicationDidFinishLaunching(_ notification: Notification) {
        axTrusted = AXIsProcessTrusted()
        Log.line("LAUNCH", "pid=\(getpid()) AXIsProcessTrusted=\(axTrusted) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")

        let size = NSSize(width: 360, height: 120)
        let screen = NSScreen.screens.first ?? NSScreen.main!   // screens.first = the one with the menu bar
        let sf = screen.frame
        // Just below the top edge: leave the notch / menu-bar band (safe area top inset, 32 pt on
        // the built-in display) plus 4 pt.
        let topInset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let origin = NSPoint(x: sf.midX - size.width / 2, y: sf.maxY - topInset - 4 - size.height)

        panel = ShelfPanel(contentRect: NSRect(origin: origin, size: size),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false      // NSPanel default is true; we are never active
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true

        shelf = ShelfView(frame: NSRect(origin: .zero, size: size))
        shelf.autoresizingMask = [.width, .height]
        panel.contentView = shelf
        panel.orderFrontRegardless()
        Log.line("PANEL", "frame=\(NSStringFromRect(panel.frame)) screen=\(NSStringFromRect(sf)) safeTop=\(screen.safeAreaInsets.top) level=statusBar registeredTypes=\(shelf.registeredDraggedTypes.map(\.rawValue))")

        monitor.onSessionStart = { [weak self] types in
            self?.shelf.setSessionHighlight(true, reason: types.joined(separator: ","))
            Log.line("PANEL", "highlight ON")
        }
        monitor.onSessionEnd = { [weak self] in
            self?.shelf.setSessionHighlight(false, reason: "")
            Log.line("PANEL", "highlight OFF")
        }
        monitor.start()

        switch mode {
        case .selftest(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finishSelftest() }
        case .normal(let quitAfter):
            if let quitAfter {
                Log.line("LAUNCH", "will quit after \(quitAfter)s")
                DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) {
                    Log.line("LAUNCH", "quit-after elapsed, exiting")
                    exit(0)
                }
            }
        }
    }

    func finishSelftest() {
        let st = monitor.status
        let f = panel.frame
        let obj: [String: Any] = [
            "axTrusted": axTrusted,
            "globalMonitorInstalled": st.globalMonitorInstalled,
            "localMonitorInstalled": st.localMonitorInstalled,
            "dragPasteboardChangeCount": st.changeCount,
            "registeredTypes": shelf.registeredDraggedTypes.map(\.rawValue).sorted(),
            "panelFrame": ["x": f.origin.x, "y": f.origin.y, "width": f.width, "height": f.height],
            "panelVisible": panel.isVisible,
            "panelLevel": panel.level.rawValue,
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        fflush(stdout)
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(mode: mode)
app.delegate = delegate
app.run()
