import Foundation
import NotchCore
import Observation
import os
import SwiftUI

/// A Yoink-style shelf. When a drag starts anywhere, the notch opens as a drop
/// target; dropped items stay until they are dragged out or removed.
///
/// What it shows, derived from its state in `desiredMode`:
/// - a drag of another app is in progress: the shelf expanded, taking drops;
/// - its own drag-out is in progress: the shelf expanded, taking no drops, so
///   it stays open while the pointer is outside the notch;
/// - a late drop may still come: see `lateDropGrace`;
/// - it holds items: nothing at rest (or the count beside the notch),
///   expanding on hover; while the pointer is on it, it keeps the notch;
/// - otherwise nothing.
@MainActor
public final class ShelfBlock: NotchBlock {
    public let id: BlockID = "shelf"
    public let title = "Shelf"
    public let info = BlockInfo(
        summary: "Holds files, links and text you drop on the notch, and new screenshots, until you drag them out again.",
        symbol: "tray.full",
        trigger: "Dragging something toward the notch, or taking a screenshot"
    )

    /// View state the block drives. The views observe it.
    @MainActor
    @Observable
    final class UIState {
        /// A drag of another app is in progress: show the drop affordance.
        var isDropTarget = false
        /// Waiting for promised files after a release over the notch.
        var isReceiving = false
        /// The stack shown as single items, if any.
        var expandedStackID: UUID?
    }

    enum Mode: Equatable {
        case none
        case dropTarget
        case dragOut
        case receiving
        case ambient
        /// Holding items, with the pointer on the open shelf.
        case browsing
    }

    static let acceptedKinds: Set<DropKind> = [.file, .link, .text]
    static let expandedSize = CGSize(width: 500, height: 180)
    /// The count beside the notch. Only the width matters. Kept narrow: the
    /// app menus can end about 45 pt from the notch, and the wing must not reach them.
    static let wingSize = CGSize(width: 42, height: 32)

    let store: ShelfStore
    let settings: ShelfSettings
    let ui = UIState()
    private(set) var mode: Mode = .none

    private var context: (any BlockContext)?
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "shelf")
    private lazy var dragOutSource = DragOutSource(
        onEnd: { [weak self] target, succeeded in self?.endDragOut(target, succeeded: succeeded) }
    )

    /// Late drops. The shell delivers a drop with promised files only after
    /// the files are written, up to 15 s after the mouse-up, and the runtime
    /// forwards a drop only to the block that owns the notch. So when a drag
    /// ends with the pointer over the notch and no drop has arrived yet, the
    /// shelf keeps an interactive presentation that takes drops for this long,
    /// a little over the shell's 15 s limit, or until the drop arrives.
    private let lateDropGrace: Duration

    private var pointerInside = false
    /// The pointer is on the shelf while the shelf is what the notch shows.
    private var isBrowsing = false
    /// Another app's drag is in progress.
    private var isDragActive = false
    /// The shelf's own drag-out is in progress.
    private var isDraggingOut = false
    /// The drag session the monitor reported was the shelf's own drag-out.
    private var ownDragSession = false
    private var droppedThisSession = false
    private var graceTask: Task<Void, Never>?

    public convenience init() {
        self.init(directory: ShelfStore.defaultDirectory)
    }

    init(directory: URL, lateDropGrace: Duration = .seconds(16), defaults: UserDefaults = .standard) {
        store = ShelfStore(directory: directory)
        settings = ShelfSettings(defaults: defaults)
        self.lateDropGrace = lateDropGrace
        settings.onChange = { [weak self] in self?.presentAgain() }
    }

    // MARK: NotchBlock

    public func activate(_ context: any BlockContext) {
        self.context = context
        context.subscribe(to: DragSessionStarted.self) { [weak self] _ in self?.dragStarted() }
        context.subscribe(to: DragSessionEnded.self) { [weak self] _ in self?.dragEnded() }
        context.subscribe(to: PointerHoverChanged.self) { [weak self] event in
            guard let self else { return }
            self.pointerInside = event.isInside
            // In use only when the shelf is what the pointer landed on, not
            // when it landed on another block's presentation.
            self.isBrowsing = event.isInside && (self.context?.ownsNotch ?? false)
            self.refresh()
        }
        // The shelf hears about screenshots from the event source, not from
        // the rename block, so each block works with the other one off. When
        // the rename block renames the file, the item's bookmark follows it.
        context.subscribe(to: ScreenshotCaptured.self) { [weak self] event in
            self?.screenshotCaptured(event.url)
        }
        store.pruneMissing()
        mode = .none
        refresh()
    }

    public func deactivate() {
        graceTask?.cancel()
        graceTask = nil
        context = nil
        mode = .none
        isDragActive = false
        isDraggingOut = false
        ownDragSession = false
        pointerInside = false
        isBrowsing = false
        ui.isDropTarget = false
        ui.isReceiving = false
    }

    public func handle(_ input: NotchInput) {
        guard case let .drop(items) = input else { return }
        store.add(items)
        droppedThisSession = true
        endGrace()
        refresh()
    }

    public var actions: [BlockAction] {
        [BlockAction(id: "shelf.clear", title: "Clear Shelf", isEnabled: !store.isEmpty) { [weak self] in
            self?.clear()
        }]
    }

    public var settingsPane: AnyView? {
        AnyView(ShelfSettingsView(settings: settings))
    }

    // MARK: Events

    private func screenshotCaptured(_ url: URL) {
        guard settings.collectScreenshots else { return }
        // Held by reference: the file stays where macOS saved it.
        store.add([.file(url)])
        refresh()
    }

    private func dragStarted() {
        if isDraggingOut {
            ownDragSession = true
            return
        }
        isDragActive = true
        droppedThisSession = false
        endGrace()
        store.pruneMissing()
        refresh()
    }

    private func dragEnded() {
        if ownDragSession {
            ownDragSession = false
            refresh()
            return
        }
        guard isDragActive else { return }
        isDragActive = false
        if pointerInside && !droppedThisSession { startGrace() }
        refresh()
    }

    private func startGrace() {
        graceTask?.cancel()
        let grace = lateDropGrace
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self else { return }
            self.graceTask = nil
            self.refresh()
        }
    }

    private func endGrace() {
        graceTask?.cancel()
        graceTask = nil
    }

    // MARK: View actions

    func remove(_ target: ShelfTarget) {
        store.remove(target)
        refresh()
    }

    func clear() {
        store.clear()
        refresh()
    }

    func quickLook(_ target: ShelfTarget) {
        let urls = store.items(for: target).compactMap { store.fileURL(of: $0) }
        QuickLookPresenter.shared.show(urls)
    }

    /// The tile is about to start a drag-out. Called before the drag begins,
    /// so the monitor's session event for it is recognised as the shelf's own.
    func beginDragOut(_ target: ShelfTarget) -> DragOutSource {
        isDraggingOut = true
        dragOutSource.target = target
        refresh()
        return dragOutSource
    }

    /// The drag-out ended. A drop elsewhere takes the items off the shelf; a
    /// cancelled or refused drop leaves them.
    func endDragOut(_ target: ShelfTarget, succeeded: Bool) {
        isDraggingOut = false
        if succeeded {
            // Owned files stay on disk until the next launch's sweep: the
            // receiving app may still be reading them.
            store.remove(target, deleteOwnedFiles: false)
            log.info("drag-out finished, items left the shelf")
        }
        refresh()
    }

    // MARK: Presentation

    private var desiredMode: Mode {
        if isDraggingOut { return .dragOut }
        if isDragActive { return .dropTarget }
        if graceTask != nil { return .receiving }
        if store.isEmpty { return .none }
        return isBrowsing ? .browsing : .ambient
    }

    /// Bring the notch in line with the state. Presents only when the mode
    /// changes: a new presentation rebuilds the views, and the views already
    /// follow the store.
    private func refresh() {
        ui.isDropTarget = isDragActive
        ui.isReceiving = graceTask != nil
        if let expanded = ui.expandedStackID, store.stack(expanded) == nil { ui.expandedStackID = nil }

        let next = desiredMode
        guard next != mode, let context else { return }
        mode = next
        if let presentation = presentation(for: next) {
            context.present(presentation)
        } else {
            context.dismiss()
        }
    }

    /// Rebuild the presentation for the current mode, after a setting changed.
    private func presentAgain() {
        guard let context, let presentation = presentation(for: mode) else { return }
        context.present(presentation)
    }

    private func presentation(for mode: Mode) -> Presentation? {
        let store = self.store
        let ui = self.ui
        let actions = ShelfActions(
            remove: { [weak self] in self?.remove($0) },
            clear: { [weak self] in self?.clear() },
            quickLook: { [weak self] in self?.quickLook($0) },
            beginDragOut: { [weak self] in self?.beginDragOut($0) }
        )
        let expanded = NotchContent(size: Self.expandedSize) {
            ShelfView(store: store, ui: ui, actions: actions)
        }
        // With the count off, a wing of no width: the shape stays the notch
        // itself and takes no room, and hovering it still opens the shelf.
        let wing = settings.showCount
            ? NotchContent(size: Self.wingSize) { ShelfPeekView(store: store, ui: ui) }
            : NotchContent(size: .zero) { EmptyView() }
        switch mode {
        case .none:
            return nil
        case .dropTarget:
            return Presentation(priority: .interactive, expanded: expanded, opensAt: .expanded, accepts: Self.acceptedKinds)
        case .dragOut:
            return Presentation(priority: .interactive, expanded: expanded, opensAt: .expanded)
        case .receiving:
            return Presentation(priority: .interactive, wing: wing, expanded: expanded, opensAt: .peek, accepts: Self.acceptedKinds)
        case .browsing:
            // Interactive while in use, so another block's news (a renamed
            // screenshot) waits until the pointer leaves, instead of
            // replacing the shelf under the pointer.
            return Presentation(priority: .interactive, wing: wing, expanded: expanded, opensAt: .peek, accepts: Self.acceptedKinds)
        case .ambient:
            // Takes drops too, so a promise that outlives the grace period is
            // still kept while the shelf owns the notch.
            return Presentation(priority: .ambient, wing: wing, expanded: expanded, opensAt: .peek, accepts: Self.acceptedKinds)
        }
    }
}

/// What the views may ask the block to do.
@MainActor
struct ShelfActions {
    let remove: @MainActor (ShelfTarget) -> Void
    let clear: @MainActor () -> Void
    let quickLook: @MainActor (ShelfTarget) -> Void
    /// Returns the dragging source, or nil when the block is gone.
    let beginDragOut: @MainActor (ShelfTarget) -> DragOutSource?
}
