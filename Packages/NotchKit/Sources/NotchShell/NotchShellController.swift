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
        screenChanged()
    }

    public func stop() {
        isStarted = false
        setPollInterval(nil)
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
    static let slowInterval: TimeInterval = 1.0 / 10.0
    /// How close to the panel the pointer must be for fast polling.
    static let nearMargin: CGFloat = 120

    /// How often to look at the pointer. Fast while it is on the shape or
    /// near the panel, so hover and drops feel immediate; slow while it is
    /// elsewhere, so an idle app wakes the CPU 10 times a second, not 60.
    /// The worst case is one slow interval of delay before fast polling
    /// starts, with the pointer still `nearMargin` away from the panel.
    static func pollInterval(pointer: CGPoint, panelFrame: CGRect, isInside: Bool) -> TimeInterval {
        let near = panelFrame.insetBy(dx: -nearMargin, dy: -nearMargin)
        return isInside || near.contains(pointer) ? fastInterval : slowInterval
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
        setPollInterval(Self.pollInterval(pointer: pointer, panelFrame: panel.frame, isInside: hover.isInside))
    }
}
