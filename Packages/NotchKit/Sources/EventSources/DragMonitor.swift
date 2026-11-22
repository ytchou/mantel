import AppKit
import NotchCore
import os

/// Notices a drag with content starting anywhere on screen and publishes
/// `DragSessionStarted` and `DragSessionEnded`. Needs no Accessibility
/// permission: global *mouse* monitors do not require it (measured in the
/// drag spike, `spikes/FINDINGS.md` decision 2).
///
/// Signals, fed into `DragStateMachine`:
/// - a global and a local `NSEvent` monitor for left mouse-down, dragged and
///   up. The local one sees drags that start in this app, such as a
///   block's own drag-out; a global monitor never sees this app's events.
/// - a 50 ms timer, running only while the button is held, that reads the
///   drag pasteboard change count and `NSEvent.pressedMouseButtons`. The
///   button poll is a second source of mouse-up, for drag loops in which the
///   monitor may not get the event.
@MainActor
public final class DragMonitor {
    private let runtime: NotchRuntime
    private let pasteboard = NSPasteboard(name: .drag)
    private var machine = DragStateMachine()
    private(set) var globalMonitor: Any?
    private(set) var localMonitor: Any?
    private var timer: Timer?
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "drag")

    private static let pollInterval: TimeInterval = 0.05
    private static let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes)

    public init(runtime: NotchRuntime) {
        self.runtime = runtime
    }

    public func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.type) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.type) }
            return event
        }
        let installed = globalMonitor != nil && localMonitor != nil
        log.info("drag monitor started, monitors installed: \(installed)")
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        apply(machine.mouseUp())
        stopTimer()
    }

    // MARK: Signals

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            apply(machine.mouseDown(changeCount: pasteboard.changeCount))
        case .leftMouseDragged:
            apply(machine.dragged(changeCount: pasteboard.changeCount))
        case .leftMouseUp:
            apply(machine.mouseUp())
        default:
            return
        }
        updateTimer()
    }

    private func poll() {
        apply(machine.polled(changeCount: pasteboard.changeCount))
        if NSEvent.pressedMouseButtons & 1 == 0 {
            apply(machine.mouseUp())
        }
        updateTimer()
    }

    private func apply(_ output: DragStateMachine.Output?) {
        switch output {
        case .started:
            let kinds = currentKinds()
            log.debug("drag session started kinds=\(kinds.count)")
            runtime.dragSessionChanged(active: true)
            runtime.publish(DragSessionStarted(kinds: kinds))
        case .ended:
            log.debug("drag session ended")
            runtime.dragSessionChanged(active: false)
            runtime.publish(DragSessionEnded())
        case nil:
            break
        }
    }

    /// Kinds from the types of each drag pasteboard item. Reads types only,
    /// never contents.
    private func currentKinds() -> Set<DropKind> {
        let itemTypes = (pasteboard.pasteboardItems ?? []).map { item -> [String] in
            var types = item.types.map(\.rawValue)
            if !Self.promiseTypes.isDisjoint(with: types) { types.append("public.file-url") }
            return types
        }
        return dragKinds(itemTypes: itemTypes)
    }

    // MARK: Timer

    /// Run the poll only while a button is held: then the change count and
    /// the button state matter. Common modes keep it firing in this app's own
    /// event tracking loops, such as a drag-out.
    private func updateTimer() {
        if machine.isArmed || machine.isActive {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            stopTimer()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
