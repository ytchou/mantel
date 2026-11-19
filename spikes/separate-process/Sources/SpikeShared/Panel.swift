import AppKit

/// Same panel recipe as spikes/notch-window: borderless, non-activating,
/// never key or main, clear, all Spaces, above the menu bar.
public final class SpikePanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    public init(frame: CGRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        // After isFloatingPanel: its setter resets the level to .floating (3).
        self.level = level
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }
}

/// Tag on synthetic events, so a real click by a person during an automated
/// run is ignored instead of polluting the numbers.
public let injectedEventNumber = 0x5EED

/// A view that takes every mouse-down in its window (the notch "input
/// surface"), stamping the time it arrived.
public final class InputView: NSView {
    /// (receipt time, injected?)
    public var onMouseDown: ((Double, Bool) -> Void)?
    public var acceptRealEvents = false
    public var onDrag: ((String, Bool) -> Void)?  // (file name, dropped?)

    public override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        let t = now()
        let injected = event.eventNumber == injectedEventNumber
        if injected || acceptRealEvents { onMouseDown?(t, injected) }
    }

    /// Inject a mouse-down + mouse-up at the view's centre through
    /// `NSWindow.sendEvent` (AppKit dispatch inside this process only; nothing
    /// system-wide is posted).
    public func injectClick() {
        guard let w = window else { return }
        let p = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: injectedEventNumber,
                                          clickCount: 1, pressure: 1) {
                w.sendEvent(e)
            }
        }
    }

    // Real drags (manual check only). Synthetic NSDraggingInfo cannot be built.
    public func enableDrops() { registerForDraggedTypes([.fileURL]) }
    private func name(_ info: NSDraggingInfo) -> String {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        return urls?.first?.lastPathComponent ?? "?"
    }
    private var lastDragName = ""
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        lastDragName = name(sender); onDrag?(lastDragName, false); return .copy
    }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrag?(name(sender), true); return true }
}

/// NotchLayout shared by host and block. Panel-local coordinates are AppKit
/// (origin bottom-left).
public struct NotchLayout {
    public static let notchHeightFallback: CGFloat = 32
    public static let inset: CGFloat = 12
    public static let expanded = CGSize(width: 440, height: 150)
    public static let collapsed = CGSize(width: 340, height: 110)
    public static let panelSize = CGSize(width: 500, height: 180)

    public let notch: CGRect
    public let panelFrame: CGRect

    public init(screen: NSScreen) {
        var notch = CGRect(x: screen.frame.midX - 92, y: screen.frame.maxY - 32, width: 185, height: 32)
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            let h = screen.safeAreaInsets.top
            notch = CGRect(x: screen.frame.minX + l.maxX, y: screen.frame.maxY - h, width: r.minX - l.maxX, height: h)
        }
        self.notch = notch
        panelFrame = CGRect(x: notch.midX - Self.panelSize.width / 2, y: screen.frame.maxY - Self.panelSize.height,
                            width: Self.panelSize.width, height: Self.panelSize.height)
    }

    public func shapeSize(expanded: Bool) -> CGSize { expanded ? Self.expanded : Self.collapsed }

    public func contentSize(expanded: Bool) -> CGSize {
        let s = shapeSize(expanded: expanded)
        return CGSize(width: s.width - 2 * Self.inset, height: s.height - notch.height - Self.inset)
    }

    /// Content area in panel-local AppKit coordinates.
    public func contentRectInPanel(expanded: Bool) -> CGRect {
        let c = contentSize(expanded: expanded)
        return CGRect(x: (Self.panelSize.width - c.width) / 2, y: Self.panelSize.height - notch.height - c.height,
                      width: c.width, height: c.height)
    }

    /// Shape in panel-local AppKit coordinates.
    public func shapeRectInPanel(expanded: Bool) -> CGRect {
        let s = shapeSize(expanded: expanded)
        return CGRect(x: (Self.panelSize.width - s.width) / 2, y: Self.panelSize.height - s.height, width: s.width, height: s.height)
    }

    public func toScreen(_ r: CGRect) -> CGRect { r.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY) }
}
