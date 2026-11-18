import AppKit
import SwiftUI

/// Run a block on the main queue after a delay, on the main actor.
func after(_ seconds: Double, _ block: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        MainActor.assumeIsolated { block() }
    }
}

@MainActor
final class SpikeController: NSObject, NSApplicationDelegate {
    let options: Options
    let level: NSWindow.Level
    var panel: NotchPanel!
    var model: NotchModel!

    // Hover
    static let expandDelay: Double = 0.25
    var hoverEnabled = true
    var hovering = false
    var hoverTimer: Timer?
    var expandWork: DispatchWorkItem?

    // Evidence collected for logs / self-test JSON
    var statesVisited: [String] = []
    var appBecameActive = false
    var panelBecameKey = false
    var frontmostBefore = "nil"
    /// Set by the self-test while the cursor is warped into the notch.
    var warpActive = false
    var hoverFiredFromWarp = false
    var swiftUIHoverFiredFromWarp = false

    init(options: Options) {
        self.options = options
        self.level = resolveLevel(options.levelName)
        super.init()
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        frontmostBefore = describeApp(NSWorkspace.shared.frontmostApplication)
        log("launch", "frontmost=\(frontmostBefore) NSApp.isActive=\(NSApp.isActive) activationPolicy=accessory")
        observeFocus()

        let screen = Self.pickScreen()
        logScreen(screen)
        let geometry = NotchGeometry.compute(screen: screen, forcePill: options.forcePill)
        model = NotchModel(geometry: geometry)
        model.onSwiftUIHover = { [weak self] inside in self?.swiftUIHover(inside) }

        panel = NotchPanel(frame: geometry.panelFrame, level: level)
        let host = NSHostingView(rootView: NotchRootView(model: model))
        // Do not let SwiftUI resize the window from the content's intrinsic size.
        host.sizingOptions = []
        panel.contentView = host
        observePanel()

        log("geometry", "mode=\(geometry.isNotchMode ? "notch" : "pill") screenHasNotch=\(geometry.screenHasNotch) notchRect=\(fmt(geometry.anchorRect))")
        log("panel", "frame(requested)=\(fmt(geometry.panelFrame)) level=\(options.levelName)(\(level.rawValue)) collectionBehavior=\(panel.collectionBehavior.rawValue)")

        recordState(.idle, reason: "initial")
        // orderFrontRegardless: shows the panel without activating the app.
        panel.orderFrontRegardless()
        log("panel shown", "frame(actual)=\(fmt(panel.frame)) isVisible=\(panel.isVisible) isKey=\(panel.isKeyWindow) NSApp.isActive=\(NSApp.isActive) frontmost=\(describeApp(NSWorkspace.shared.frontmostApplication))")

        startHoverPolling()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }

        if let seconds = options.selftestSeconds {
            runSelfTest(seconds: seconds)
        } else {
            if let q = options.quitAfter {
                log("mode", "normal; quitting after \(q)s")
                after(q) {
                    log("quit", "quit-after elapsed")
                    exit(0)
                }
            } else {
                log("mode", "normal; Ctrl-C to quit")
            }
        }
    }

    /// Prefer the screen that has a notch (built-in display), else the first screen.
    static func pickScreen() -> NSScreen {
        NSScreen.screens.first { NotchGeometry.notchRect(of: $0) != nil }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func logScreen(_ s: NSScreen) {
        let i = s.safeAreaInsets
        log("screen", "name=\(s.localizedName) frame=\(fmt(s.frame)) visibleFrame=\(fmt(s.visibleFrame)) safeAreaInsets=(t:\(i.top) l:\(i.left) b:\(i.bottom) r:\(i.right)) auxTopLeft=\(s.auxiliaryTopLeftArea.map { fmt($0) } ?? "nil") auxTopRight=\(s.auxiliaryTopRightArea.map { fmt($0) } ?? "nil") screens=\(NSScreen.screens.count)")
    }

    func screenChanged() {
        let screen = Self.pickScreen()
        logScreen(screen)
        let g = NotchGeometry.compute(screen: screen, forcePill: options.forcePill)
        model.geometry = g
        panel.setFrame(g.panelFrame, display: true)
        log("panel reframed", "frame=\(fmt(panel.frame)) notchRect=\(fmt(g.anchorRect))")
    }

    // MARK: Focus evidence

    func observeFocus() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            log("frontmost changed", describeApp(app))
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appBecameActive = true
                log("NSApp became ACTIVE", "(focus stolen) frontmost=\(describeApp(NSWorkspace.shared.frontmostApplication))")
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { _ in
            log("NSApp resigned active")
        }
    }

    func observePanel() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panelBecameKey = true
                log("panel became KEY", "(should never happen)")
            }
        }
    }

    // MARK: State

    func recordState(_ s: NotchState, reason: String) {
        statesVisited.append(s.rawValue)
        log("state", "\(s.rawValue) reason=\(reason) shapeRect=\(fmt(model.geometry.shapeRect(for: s)))")
    }

    func setState(_ s: NotchState, reason: String) {
        guard s != model.state else { return }
        let old = model.state
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            model.state = s
        }
        log("state change", "\(old.rawValue) -> \(s.rawValue)")
        recordState(s, reason: reason)
        log("frontmost", "\(describeApp(NSWorkspace.shared.frontmostApplication)) NSApp.isActive=\(NSApp.isActive) panel.isKey=\(panel.isKeyWindow)")
    }

    // MARK: Hover (polling)

    func startHoverPolling() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollHover() }
        }
    }

    /// Inclusive containment; the top edge counts so a cursor pinned at the very top
    /// of the screen still hits the notch.
    func cursorInsideShape(_ p: CGPoint) -> Bool {
        let r = model.geometry.shapeRect(for: model.state)
        return p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY + 1
    }

    func pollHover() {
        let p = NSEvent.mouseLocation
        let inside = cursorInsideShape(p)

        // Hit testing: only the black shape takes mouse events.
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }

        guard hoverEnabled else { return }

        if inside, !hovering {
            hovering = true
            if warpActive { hoverFiredFromWarp = true }
            log("hover enter", "source=poll cursor=\(fmt(p)) warp=\(warpActive)")
            if model.state == .idle { setState(.peek, reason: "hover") }
            expandWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hovering, self.hoverEnabled else { return }
                    self.setState(.expanded, reason: "hover+\(Self.expandDelay)s")
                }
            }
            expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandDelay, execute: work)
        } else if !inside, hovering {
            hovering = false
            expandWork?.cancel()
            log("hover exit", "source=poll cursor=\(fmt(p))")
            setState(.idle, reason: "hover exit")
        }
    }

    func swiftUIHover(_ inside: Bool) {
        if inside, warpActive { swiftUIHoverFiredFromWarp = true }
        log(inside ? "hover enter" : "hover exit", "source=swiftui-onHover warp=\(warpActive)")
    }
}
