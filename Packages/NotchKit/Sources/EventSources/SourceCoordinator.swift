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
///
/// It owns the runtime's `onDemandChanged`; a closure set there before it is
/// still called.
@MainActor
public final class SourceCoordinator {
    private struct Entry {
        let source: any EventSource
        let types: [any NotchEvent.Type]
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

    /// Run `source` while any of `types` has a subscriber. Starts it at once
    /// when one already has.
    public func add(_ source: any EventSource, for types: [any NotchEvent.Type]) {
        entries.append(Entry(source: source, types: types))
        evaluate()
    }

    private func evaluate() {
        for index in entries.indices {
            let wanted = entries[index].types.contains { runtime.hasSubscribers(for: $0) }
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
