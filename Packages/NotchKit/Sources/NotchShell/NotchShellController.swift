import AppKit
import NotchCore

/// Owns the notch window. Draws what the runtime says and reports hover, click
/// and drop back to it. Knows nothing about any specific block.
@MainActor
public final class NotchShellController {
    private let runtime: NotchRuntime
    private var layout: ShellLayout?
    private var panel: NotchPanel?
    private var timer: Timer?
    private var screenObserver: (any NSObjectProtocol)?
    private var hover = HoverTracker()
    private var isStarted = false
    /// Mouse-event monitors that drive `poll()` while the pointer moves.
    private var monitors: [Any] = []

    /// Where the notch is now, or nil when there is no screen.
    private let geometryProvider: @MainActor () -> NotchGeometry?

    /// Builds the menu shown on a right-click on the notch. Set before `start()`.
    public var contextMenu: (@MainActor () -> NSMenu?)?

    /// `forcePill` draws the floating pill even on a screen with a notch.
    public convenience init(runtime: NotchRuntime, forcePill: Bool = false) {
        self.init(runtime: runtime, geometryProvider: { NotchGeometry.current(forcePill: forcePill) })
    }

    /// For tests: the screens are made up.
    init(runtime: NotchRuntime, geometryProvider: @escaping @MainActor () -> NotchGeometry?) {
        self.runtime = runtime
        self.geometryProvider = geometryProvider
    }

    /// Show the panel on the built-in (notched) screen, or the main screen as a
    /// floating pill, and start tracking. With no screen yet, the panel
    /// appears when one is connected.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        // Files from earlier drops are kept only until the next launch.
        try? FileManager.default.removeItem(at: DropTargetView.dropRoot)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
        installMonitors()
        screenChanged()
    }

    public func stop() {
        isStarted = false
        setPollInterval(nil)
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.close()
        panel = nil
        layout = nil
        resetHover()
    }

    // MARK: Screens

    /// The panel's frame while it is on screen, nil while it is hidden.
    var shownPanelFrame: CGRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    /// The geometry in use, nil before the first screen was seen.
    var geometry: NotchGeometry? { layout?.geometry }

    /// The screens changed: a display was connected or removed, the lid was
    /// closed or opened, or the resolution changed. Moves the panel to where
    /// the notch (or pill) is now, or hides it while there is no screen.
    func screenChanged() {
        guard isStarted else { return }
        // The pointer cannot be on a shape that moved or went away. The next
        // poll finds it again if it is on the new one.
        resetHover()
        guard let geometry = geometryProvider() else {
            panel?.orderOut(nil)
            setPollInterval(nil)
            return
        }
        if let panel, let layout {
            layout.geometry = geometry
            panel.setFrame(geometry.panelFrame, display: true)
            // Shows the panel without activating the app.
            panel.orderFrontRegardless()
        } else {
            makePanel(geometry)
        }
        if timer == nil { setPollInterval(Self.fastInterval) }
    }

    private func makePanel(_ geometry: NotchGeometry) {
        let layout = ShellLayout(geometry: geometry)
        let panel = NotchPanel(frame: geometry.panelFrame)

        let dropTarget = DropTargetView(frame: CGRect(origin: .zero, size: geometry.panelFrame.size))
        let runtime = self.runtime
        dropTarget.acceptedKinds = { runtime.state.presentation?.accepts ?? [] }
        dropTarget.onDrop = { items in runtime.send(.drop(items)) }

        let host = NotchHostingView(rootView: NotchShapeView(runtime: runtime, layout: layout))
        // SwiftUI must not resize the window from the content's size.
        host.sizingOptions = []
        host.menuProvider = { [weak self] in self?.contextMenu?() }
        host.frame = dropTarget.bounds
        host.autoresizingMask = [.width, .height]
        dropTarget.addSubview(host)
        panel.contentView = dropTarget

        self.layout = layout
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func resetHover() {
        if hover.isInside { runtime.pointerHoverChanged(isInside: false) }
        hover = HoverTracker()
        layout?.isHovering = false
    }

    // MARK: Tracking

    static let fastInterval: TimeInterval = 1.0 / 60.0
    /// The safety net while the pointer is away from the shape. Mouse events
    /// do the real work there; see `installMonitors`.
    static let slowInterval: TimeInterval = 1.0
    /// The timer's rate away from the shape while this app is frontmost.
    static let activeAppInterval: TimeInterval = 1.0 / 10.0
    /// How close to the shape the pointer must be for fast polling.
    static let nearMargin: CGFloat = 80

    /// How often the timer looks at the pointer. Fast while the pointer is
    /// on or near the shape on screen now, so hover and drops feel immediate
    /// and a shape that changes under a still pointer is noticed. Slow while
    /// it is elsewhere: there, every mouse move already runs a check, and
    /// the timer only covers what no mouse event reports. So an idle app
    /// with a still pointer wakes once a second, not 60 times.
    /// Measured from the shape, not the whole panel: the panel covers the
    /// top centre of the screen, where the pointer spends much of its time.
    ///
    /// `appIsActive`: while this app is frontmost (its Settings window is in
    /// use), mouse moves are not reported to it reliably, so the timer runs
    /// at `activeAppInterval` instead.
    static func pollInterval(pointer: CGPoint, shape: CGRect, isInside: Bool, appIsActive: Bool = false) -> TimeInterval {
        let near = shape.insetBy(dx: -nearMargin, dy: -nearMargin)
        if isInside || near.contains(pointer) { return fastInterval }
        return appIsActive ? activeAppInterval : slowInterval
    }

    /// Check the pointer on every mouse move or drag, anywhere. This is what
    /// notices the pointer coming toward the notch; the timer then takes
    /// over at the fast rate. Mouse events need no Accessibility permission.
    /// The global monitor covers events going to other apps, the local one
    /// events going to this app's own windows.
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.poll() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private var pollInterval: TimeInterval?

    /// Hover is polled: SwiftUI .onHover did not fire when the pointer arrived
    /// without mouse-moved events. Common modes keep it running in event
    /// tracking loops, such as during a drag that starts in this app.
    private func setPollInterval(_ interval: TimeInterval?) {
        guard interval != pollInterval else { return }
        pollInterval = interval
        timer?.invalidate()
        timer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Lets the system group wakeups; hover does not need exact timing.
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard let panel, let layout, panel.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        let shape = layout.geometry.shapeRect(for: runtime.state)

        // Only the shape takes mouse and drag events; the rest passes through.
        // NSEvent.mouseLocation keeps updating while a drag holds the button, so
        // this also lets the drop target receive drags over the shape.
        let neck = layout.geometry.neck(for: runtime.state)
        let overShape = NotchGeometry.hits(shape, pointer, neck: neck)
        if panel.ignoresMouseEvents == overShape {
            panel.ignoresMouseEvents = !overShape
        }

        if hover.update(pointer: pointer, shape: shape, neck: neck) {
            layout.isHovering = hover.isInside
            runtime.pointerHoverChanged(isInside: hover.isInside)
        }
        // The shape may have changed with the hover; use the one on screen now.
        let shown = layout.geometry.shapeRect(for: runtime.state)
        setPollInterval(Self.pollInterval(pointer: pointer, shape: shown, isInside: hover.isInside, appIsActive: NSApp.isActive))
    }
}
