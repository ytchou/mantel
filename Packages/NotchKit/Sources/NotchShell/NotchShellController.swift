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

    private let forcePill: Bool

    /// Builds the menu shown on a right-click on the notch. Set before `start()`.
    public var contextMenu: (@MainActor () -> NSMenu?)?

    /// `forcePill` draws the floating pill even on a screen with a notch.
    public init(runtime: NotchRuntime, forcePill: Bool = false) {
        self.runtime = runtime
        self.forcePill = forcePill
    }

    /// Create the panel on the built-in (notched) screen, or the main screen as a
    /// floating pill, and start tracking.
    public func start() {
        guard panel == nil, let geometry = NotchGeometry.current(forcePill: forcePill) else { return }
        // Files from earlier drops are kept only until the next launch.
        try? FileManager.default.removeItem(at: DropTargetView.dropRoot)
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
        // Shows the panel without activating the app.
        panel.orderFrontRegardless()

        // Hover is polled: SwiftUI .onHover did not fire when the pointer arrived
        // without mouse-moved events. Common modes keep it running in event
        // tracking loops, such as during a drag that starts in this app.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.close()
        panel = nil
        layout = nil
        if hover.isInside { runtime.pointerHoverChanged(isInside: false) }
        hover = HoverTracker()
    }

    // MARK: Tracking

    private func poll() {
        guard let panel, let layout else { return }
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
    }

    private func screenChanged() {
        guard let panel, let layout, let geometry = NotchGeometry.current(forcePill: forcePill) else { return }
        layout.geometry = geometry
        panel.setFrame(geometry.panelFrame, display: true)
    }
}
