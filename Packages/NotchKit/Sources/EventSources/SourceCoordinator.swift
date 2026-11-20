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
/// while an interactive presentation is on screen.
///
/// It owns the runtime's `onDemandChanged`; a closure set there before it is
/// still called.
@MainActor
public final class SourceCoordinator {
    private struct Entry {
        let source: any EventSource
        let types: [any NotchEvent.Type]
        let whileInteractiveShows: Bool
        var isRunning = false
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
    /// presentation. Starts it at once when that already holds.
    public func add(_ source: any EventSource, for types: [any NotchEvent.Type], whileInteractiveShows: Bool = false) {
        entries.append(Entry(source: source, types: types, whileInteractiveShows: whileInteractiveShows))
        evaluate()
    }

    private func evaluate() {
        for index in entries.indices {
            let wanted = entries[index].types.contains { runtime.hasSubscribers(for: $0) }
                || (entries[index].whileInteractiveShows && runtime.isShowingInteractive)
            guard wanted != entries[index].isRunning else { continue }
            // Marked first: a source that publishes on stop can change demand
            // and bring us back here.
            entries[index].isRunning = wanted
            if wanted { entries[index].source.start() } else { entries[index].source.stop() }
        }
    }
}

extension DragMonitor: EventSource {}
extension ScreenshotWatcher: EventSource {}
extension OutputVolumeWatcher: EventSource {}
extension PlayerNotificationWatcher: EventSource {}
extension SystemNowPlayingWatcher: EventSource {}
