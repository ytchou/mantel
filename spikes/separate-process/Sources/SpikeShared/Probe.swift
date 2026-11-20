import AppKit
import QuartzCore

/// Measures "input applied" -> "frame that shows it", inside one process.
///
/// 1. The caller registers `expect(version:)` before it changes the model.
/// 2. The SwiftUI body that shows `version` calls `bodyEvaluated(version:)`
///    -> tBody (SwiftUI has evaluated the new state).
/// 3. A main run-loop observer for `beforeWaiting` with the highest order
///    runs after Core Animation's own commit observer (order 2000000) and
///    AppKit's display cycle -> tCommit: the end of the run-loop pass in which
///    the body ran, after the implicit CA transaction holding the new layer
///    tree was committed to the render server. (CATransaction commit handlers
///    are not public on macOS.)
/// 4. The first display-link tick after the commit gives its `targetTimestamp`
///    -> tFrame, an ESTIMATE of when that frame is on the glass (the render
///    server composites the commit for the next vsync). It is not a photon
///    measurement.
@MainActor
public enum Probe {
    public typealias Done = (_ tBody: Double, _ tCommit: Double, _ tFrame: Double) -> Void
    private static var pending: [Int: Done] = [:]
    public static var commitHandlerFailures = 0

    public static func expect(version: Int, timeout: Double = 1.0, done: @escaping Done) {
        installObserver()
        pending[version] = done
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if let d = pending.removeValue(forKey: version) { d(.nan, .nan, .nan) }
        }
    }

    public static func bodyEvaluated(version: Int) {
        guard let done = pending.removeValue(forKey: version) else { return }
        let tBody = now()
        installObserver()
        awaitingCommit.append((tBody, done))
    }

    private static var awaitingCommit: [(Double, Done)] = []
    private static var observer: CFRunLoopObserver?

    private static func installObserver() {
        guard observer == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                   true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                guard !awaitingCommit.isEmpty else { return }
                let tCommit = now()
                let list = awaitingCommit
                awaitingCommit.removeAll()
                for (tBody, done) in list { FrameClock.next { tFrame in done(tBody, tCommit, tFrame) } }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
    }
}

/// Display-link ticks for the window a view is in.
@MainActor
public final class FrameClock: NSObject {
    private static var shared: FrameClock?
    private static var waiters: [(Double) -> Void] = []
    private var link: CADisplayLink?
    public static var ticks = 0

    public static func install(on view: NSView) {
        let c = FrameClock()
        c.link = view.displayLink(target: c, selector: #selector(tick(_:)))
        c.link?.add(to: .main, forMode: .common)
        shared = c
    }

    public static func uninstall() { shared?.link?.invalidate(); shared = nil }

    /// Next tick's targetTimestamp; NaN when no tick arrives within 100 ms
    /// (no display link, or the window is not on screen).
    public static func next(_ cb: @escaping (Double) -> Void) {
        guard shared != nil else { cb(.nan); return }
        var fired = false
        let wrapped: (Double) -> Void = { t in if !fired { fired = true; cb(t) } }
        waiters.append(wrapped)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wrapped(.nan) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        FrameClock.ticks += 1
        let w = FrameClock.waiters
        FrameClock.waiters.removeAll()
        for cb in w { cb(link.targetTimestamp) }
    }
}
