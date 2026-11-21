import NotchCore

/// A system event source that publishes to the runtime. `start()` and `stop()`
/// are safe to call twice: a second `start()` adds no second observer, a
/// second `stop()` does nothing.
@MainActor
public protocol EventSource: AnyObject {
    func start()
    func stop()
}

/// Runs each source only while a block listens to one of its events, so a
/// source no block needs (such as the now-playing helper process) does not run.
/// A source added with `whileInteractiveShows` (the drag monitor) also runs
/// while an interactive presentation is on screen. A source added with a
/// `consent` (the screenshot watcher) runs only once its check passes.
///
/// It owns the runtime's `onDemandChanged`; a closure set there before it is
/// still called.
@MainActor
public final class SourceCoordinator {
    /// What macOS must allow before a source runs, such as access to the
    /// screenshot folder. `ask` is called when a block first listens while
    /// `isGranted` is false; once the answer is in, call `evaluate()`.
    public struct Consent {
        public let isGranted: @MainActor () -> Bool
        public let ask: @MainActor () -> Void

        public init(isGranted: @escaping @MainActor () -> Bool, ask: @escaping @MainActor () -> Void) {
            self.isGranted = isGranted
            self.ask = ask
        }
    }

    private struct Entry {
        let source: any EventSource
        let types: [any NotchEvent.Type]
        let whileInteractiveShows: Bool
        let consent: Consent?
        var isRunning = false
        /// Whether a block listened at the last evaluation, so `ask` is
        /// called only when demand appears.
        var wasWanted = false
    }

    private let runtime: NotchRuntime
    private var entries: [Entry] = []

    public init(runtime: NotchRuntime) {
        self.runtime = runtime
        let previous = runtime.onDemandChanged
        runtime.onDemandChanged = { [weak self] in
            previous?()
            self?.evaluate()
        }
    }

    /// Run `source` while any of `types` has a subscriber, and with
    /// `whileInteractiveShows` also while the notch shows an interactive
    /// presentation. With `consent`, only while its check passes. Starts it
    /// at once when that already holds.
    public func add(
        _ source: any EventSource,
        for types: [any NotchEvent.Type],
        whileInteractiveShows: Bool = false,
        consent: Consent? = nil
    ) {
        entries.append(Entry(source: source, types: types, whileInteractiveShows: whileInteractiveShows,
                             consent: consent))
        evaluate()
    }

    /// Start or stop each source to match demand and consent. Called on every
    /// demand change; call it after a consent answer comes in.
    public func evaluate() {
        var asks: [@MainActor () -> Void] = []
        for index in entries.indices {
            let wanted = entries[index].types.contains { runtime.hasSubscribers(for: $0) }
                || (entries[index].whileInteractiveShows && runtime.isShowingInteractive)
            let granted = entries[index].consent?.isGranted() ?? true
            if wanted, !entries[index].wasWanted, !granted, let consent = entries[index].consent {
                asks.append(consent.ask)
            }
            entries[index].wasWanted = wanted
            let run = wanted && granted
            guard run != entries[index].isRunning else { continue }
            // Marked first: a source that publishes on stop can change demand
            // and bring us back here.
            entries[index].isRunning = run
            if run { entries[index].source.start() } else { entries[index].source.stop() }
        }
        // After the loop, so an answer that comes back at once re-enters
        // with every entry up to date.
        for ask in asks { ask() }
    }
}

extension DragMonitor: EventSource {}
extension ScreenshotWatcher: EventSource {}
extension OutputVolumeWatcher: EventSource {}
extension PlayerNotificationWatcher: EventSource {}
extension SystemNowPlayingWatcher: EventSource {}
