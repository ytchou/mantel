import Foundation
import NotchCore
import SwiftUI
import Testing
@testable import EventSources

/// Counts how often the coordinator starts and stops it.
@MainActor
private final class FakeSource: EventSource {
    private(set) var starts = 0
    private(set) var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

/// A block that subscribes to the given event types when turned on.
@MainActor
private final class ListeningBlock: NotchBlock {
    let id: BlockID
    let title = "Listening"
    private let types: [any NotchEvent.Type]
    private(set) var context: (any BlockContext)?

    init(_ id: BlockID, listensTo types: [any NotchEvent.Type]) {
        self.id = id
        self.types = types
    }

    func activate(_ context: any BlockContext) {
        self.context = context
        for type in types { subscribe(context, to: type) }
    }

    private func subscribe<E: NotchEvent>(_ context: any BlockContext, to type: E.Type) {
        context.subscribe(to: type) { _ in }
    }
}

// MARK: Coordinator

@MainActor
@Test func sourceStartsOnFirstSubscriberAndStopsOnLast() {
    let runtime = NotchRuntime()
    let coordinator = SourceCoordinator(runtime: runtime)
    let source = FakeSource()
    coordinator.add(source, for: [ScreenshotCaptured.self])
    #expect(source.starts == 0)

    runtime.register(ListeningBlock("a", listensTo: [ScreenshotCaptured.self]), enabled: false)
    runtime.register(ListeningBlock("b", listensTo: [ScreenshotCaptured.self]), enabled: false)
    #expect(source.starts == 0)

    runtime.setEnabled("a", true)
    #expect(source.starts == 1)
    runtime.setEnabled("b", true)
    #expect(source.starts == 1)

    runtime.setEnabled("a", false)
    #expect(source.stops == 0)
    runtime.setEnabled("b", false)
    #expect(source.stops == 1)

    runtime.setEnabled("b", true)
    #expect(source.starts == 2)
    runtime.unregister("b")
    #expect(source.stops == 2)
}

@MainActor
@Test func sourceForTwoEventsRunsWhileEitherIsWanted() {
    let runtime = NotchRuntime()
    let coordinator = SourceCoordinator(runtime: runtime)
    let drag = FakeSource()
    coordinator.add(drag, for: [DragSessionStarted.self, DragSessionEnded.self])

    runtime.register(ListeningBlock("starts", listensTo: [DragSessionStarted.self]))
    #expect(drag.starts == 1)
    runtime.register(ListeningBlock("ends", listensTo: [DragSessionEnded.self]))
    runtime.setEnabled("starts", false)
    #expect(drag.starts == 1)
    #expect(drag.stops == 0)

    runtime.setEnabled("ends", false)
    #expect(drag.stops == 1)
}

@MainActor
@Test func sourceAddedAfterBlocksStartsAtOnce() {
    let runtime = NotchRuntime()
    runtime.register(ListeningBlock("a", listensTo: [OutputVolumeChanged.self]))
    let coordinator = SourceCoordinator(runtime: runtime)
    let source = FakeSource()
    coordinator.add(source, for: [OutputVolumeChanged.self])
    #expect(source.starts == 1)
}

@MainActor
@Test func nothingStartsWhenNoBlockListens() {
    let runtime = NotchRuntime()
    let coordinator = SourceCoordinator(runtime: runtime)
    let nowPlaying = FakeSource()
    let screenshots = FakeSource()
    coordinator.add(nowPlaying, for: [NowPlayingChanged.self])
    coordinator.add(screenshots, for: [ScreenshotCaptured.self])

    runtime.register(ListeningBlock("a", listensTo: [DragSessionStarted.self, OutputVolumeChanged.self]))
    runtime.register(ListeningBlock("b", listensTo: [PointerHoverChanged.self]))
    runtime.setEnabled("a", false)
    runtime.setEnabled("a", true)

    #expect(nowPlaying.starts == 0)
    #expect(screenshots.starts == 0)
    #expect(nowPlaying.stops == 0)
    #expect(screenshots.stops == 0)
}

/// With no drag listener, the drag monitor still runs while an interactive
/// presentation is on screen, so a drag cannot displace it. Other sources
/// stay on demand.
@MainActor
@Test func dragSourceAlsoRunsWhileAnInteractivePresentationShows() {
    let runtime = NotchRuntime()
    let coordinator = SourceCoordinator(runtime: runtime)
    let drag = FakeSource()
    let screenshots = FakeSource()
    coordinator.add(drag, for: [DragSessionStarted.self, DragSessionEnded.self], whileInteractiveShows: true)
    coordinator.add(screenshots, for: [ScreenshotCaptured.self])
    let block = ListeningBlock("a", listensTo: [])
    runtime.register(block)
    func presentation(_ priority: PresentationPriority) -> Presentation {
        Presentation(priority: priority, peek: NotchContent(size: CGSize(width: 10, height: 10)) { EmptyView() })
    }

    block.context?.present(presentation(.standard))
    #expect(drag.starts == 0)

    block.context?.present(presentation(.interactive))
    #expect(drag.starts == 1)
    #expect(screenshots.starts == 0)

    block.context?.dismiss()
    #expect(drag.stops == 1)

    // A drag listener keeps it running when the presentation goes.
    runtime.register(ListeningBlock("drags", listensTo: [DragSessionStarted.self]))
    #expect(drag.starts == 2)
    block.context?.present(presentation(.interactive))
    block.context?.dismiss()
    #expect(drag.starts == 2)
    #expect(drag.stops == 1)
    #expect(screenshots.starts == 0)
}

// MARK: Real watchers

@MainActor
@Test func startAndStopAreSafeToRepeat() throws {
    let runtime = NotchRuntime()

    let drag = DragMonitor(runtime: runtime)
    drag.start()
    let global = drag.globalMonitor.map { $0 as AnyObject }
    let local = drag.localMonitor.map { $0 as AnyObject }
    drag.start()
    #expect(drag.globalMonitor.map { $0 as AnyObject } === global)
    #expect(drag.localMonitor.map { $0 as AnyObject } === local)
    drag.stop()
    drag.stop()
    #expect(drag.globalMonitor == nil)
    #expect(drag.localMonitor == nil)

    let screenshots = ScreenshotWatcher(runtime: runtime)
    screenshots.start()
    let scanner = try #require(screenshots.scanner)
    screenshots.start()
    #expect(screenshots.scanner === scanner)
    screenshots.stop()
    screenshots.stop()
    #expect(screenshots.scanner == nil)

    let volume = OutputVolumeWatcher(runtime: runtime)
    volume.start()
    #expect(volume.isRunning)
    volume.start()
    #expect(volume.isRunning)
    volume.stop()
    volume.stop()
    #expect(!volume.isRunning)

    let player = PlayerNotificationWatcher(runtime: runtime, player: .spotify)
    player.start()
    #expect(player.observers.count == 2)
    player.start()
    #expect(player.observers.count == 2)
    player.stop()
    player.stop()
    #expect(player.observers.isEmpty)

    // A file that is not the helper: perl starts, fails to load it, and exits.
    let notAHelper = FileManager.default.temporaryDirectory.appending(path: "not-a-helper-\(UUID().uuidString).dylib")
    try Data().write(to: notAHelper)
    defer { try? FileManager.default.removeItem(at: notAHelper) }
    let system = SystemNowPlayingWatcher(runtime: runtime, helperURL: notAHelper)
    system.start()
    let process = try #require(system.process)
    system.start()
    #expect(system.process === process)
    system.stop()
    system.stop()
    #expect(system.process == nil)

    // A missing helper starts nothing.
    let missing = SystemNowPlayingWatcher(runtime: runtime, helperURL: nil)
    missing.start()
    missing.start()
    #expect(missing.process == nil)
    missing.stop()
}
