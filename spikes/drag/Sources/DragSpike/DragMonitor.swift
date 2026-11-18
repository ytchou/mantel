import AppKit

/// Detects "a drag with content started somewhere on screen" without Accessibility permission.
///
/// Two raw signals, both logged separately so their timing can be compared:
///   A. NSEvent global monitor for .leftMouseDown / .leftMouseDragged / .leftMouseUp.
///      Global mouse monitors do NOT need Accessibility (only key-event monitors do).
///      They never see events aimed at this app, so a local monitor is added too for chip drags.
///   B. Polling NSPasteboard(name: .drag).changeCount every 50 ms. Any app that starts an
///      NSDraggingSession writes the drag pasteboard, which bumps the count.
///
/// Combined session definition:
///   - "armed" on mouse-down (from the event monitor, or from the poller seeing the left button
///     go down via NSEvent.pressedMouseButtons, in case the monitor misses it).
///   - session STARTS when, since that mouse-down, we have seen BOTH a mouse-dragged event AND a
///     drag-pasteboard changeCount bump. A plain click-and-drag selection (no pasteboard write)
///     or a stale pasteboard (no drag movement) does not count.
///   - session ENDS on left-mouse-up (monitor) or when the poller sees the left button released,
///     whichever comes first. The poller fallback exists because the source app may run a modal
///     drag loop and it is not verified whether the global monitor still gets .leftMouseUp then.
final class DragMonitor {
    struct Status {
        var globalMonitorInstalled: Bool
        var localMonitorInstalled: Bool
        var changeCount: Int
    }

    var onSessionStart: ((_ types: [String]) -> Void)?
    var onSessionEnd: (() -> Void)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?

    private var lastChangeCount: Int
    private var mouseDownAt: Date?
    private var sawDragEvent = false
    private var sawPasteboardChange = false
    private var dragEventCount = 0
    private var sessionActive = false
    private var sessionStartedAt: Date?
    private var pollerButtonDown = false

    init() {
        lastChangeCount = dragPasteboard.changeCount
    }

    var status: Status {
        Status(globalMonitorInstalled: globalMonitor != nil,
               localMonitorInstalled: localMonitor != nil,
               changeCount: dragPasteboard.changeCount)
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event, source: "global")
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event, source: "local")
            return event
        }
        Log.line("MONITOR", "globalMonitorInstalled=\(globalMonitor != nil) localMonitorInstalled=\(localMonitor != nil) initialDragChangeCount=\(lastChangeCount)")

        // 50 ms poll. Always on: reading changeCount is a cheap IPC call. A production version
        // could poll only while the button is down. Added to .common so it keeps firing during
        // our own event-tracking loops (chip drag-out).
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Signal A: mouse events

    private func handle(_ event: NSEvent, source: String) {
        switch event.type {
        case .leftMouseDown:
            Log.line("SIG-A", "\(source) leftMouseDown at=\(fmt(NSEvent.mouseLocation))")
            arm(reason: "\(source) leftMouseDown")
        case .leftMouseDragged:
            dragEventCount += 1
            if mouseDownAt == nil { arm(reason: "\(source) leftMouseDragged without prior down") }
            if !sawDragEvent {
                sawDragEvent = true
                Log.line("SIG-A", "\(source) first leftMouseDragged since down at=\(fmt(NSEvent.mouseLocation)) dtFromDown=\(dt(mouseDownAt))")
            }
            evaluateStart()
        case .leftMouseUp:
            Log.line("SIG-A", "\(source) leftMouseUp at=\(fmt(NSEvent.mouseLocation)) draggedEvents=\(dragEventCount)")
            end(reason: "\(source) leftMouseUp")
        default:
            break
        }
    }

    // MARK: Signal B: drag pasteboard polling (+ button-state fallback)

    private func poll() {
        let count = dragPasteboard.changeCount
        if count != lastChangeCount {
            lastChangeCount = count
            let types = currentTypes()
            Log.line("SIG-B", "drag pasteboard changeCount=\(count) mouseDown=\(mouseDownAt != nil) types=\(types)")
            if mouseDownAt != nil {
                sawPasteboardChange = true
                evaluateStart()
            } else {
                Log.line("SIG-B", "changeCount bumped while not armed (ignored)")
            }
        }

        let down = (NSEvent.pressedMouseButtons & 1) != 0
        if down != pollerButtonDown {
            pollerButtonDown = down
            Log.line("POLL", "pressedMouseButtons left=\(down ? "down" : "up")")
            if down, mouseDownAt == nil { arm(reason: "poller saw button down") }
            if !down { end(reason: "poller saw button up") }
        }
    }

    // MARK: Combination

    private func arm(reason: String) {
        if sessionActive { end(reason: "re-arm while active") }
        mouseDownAt = Date()
        sawDragEvent = false
        sawPasteboardChange = false
        dragEventCount = 0
        // Anything written to the drag pasteboard before this mouse-down is stale.
        lastChangeCount = dragPasteboard.changeCount
    }

    private func evaluateStart() {
        guard !sessionActive, sawDragEvent, sawPasteboardChange else { return }
        sessionActive = true
        sessionStartedAt = Date()
        let types = currentTypes()
        Log.line("SESSION", "drag session STARTED dtFromDown=\(dt(mouseDownAt)) draggedEvents=\(dragEventCount) changeCount=\(dragPasteboard.changeCount) types=\(types)")
        onSessionStart?(types)
    }

    private func end(reason: String) {
        if sessionActive {
            sessionActive = false
            Log.line("SESSION", "drag session ENDED by=\(reason) duration=\(dt(sessionStartedAt))")
            onSessionEnd?()
        } else if mouseDownAt != nil {
            Log.line("SESSION", "mouse released with no drag session (dragEvent=\(sawDragEvent) pbChange=\(sawPasteboardChange)) by=\(reason)")
        }
        mouseDownAt = nil
        sawDragEvent = false
        sawPasteboardChange = false
        sessionStartedAt = nil
    }

    // MARK: Helpers

    private func currentTypes() -> [String] {
        let top = dragPasteboard.types?.map(\.rawValue) ?? []
        let items = dragPasteboard.pasteboardItems?.count ?? 0
        return top + ["(items=\(items))"]
    }

    private func dt(_ since: Date?) -> String {
        guard let since else { return "n/a" }
        return String(format: "%.0fms", Date().timeIntervalSince(since) * 1000)
    }

    private func fmt(_ p: NSPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
}
