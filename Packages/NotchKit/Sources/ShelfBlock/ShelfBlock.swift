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
/// - it holds items: a peek with the count, expanding on hover;
/// - otherwise nothing.
@MainActor
public final class ShelfBlock: NotchBlock {
    public let id: BlockID = "shelf"
    public let title = "Shelf"

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
    }

    static let acceptedKinds: Set<DropKind> = [.file, .link, .text]
    static let expandedSize = CGSize(width: 500, height: 168)
    static let peekSize = CGSize(width: 120, height: 32)

    let store: ShelfStore
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

    init(directory: URL, lateDropGrace: Duration = .seconds(16)) {
        store = ShelfStore(directory: directory)
        self.lateDropGrace = lateDropGrace
    }

    // MARK: NotchBlock

    public func activate(_ context: any BlockContext) {
        self.context = context
        context.subscribe(to: DragSessionStarted.self) { [weak self] _ in self?.dragStarted() }
        context.subscribe(to: DragSessionEnded.self) { [weak self] _ in self?.dragEnded() }
        context.subscribe(to: PointerHoverChanged.self) { [weak self] event in
            self?.pointerInside = event.isInside
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

    // MARK: Events

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
        return store.isEmpty ? .none : .ambient
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
        let peek = NotchContent(size: Self.peekSize) {
            ShelfPeekView(store: store, ui: ui)
        }
        switch mode {
        case .none:
            return nil
        case .dropTarget:
            return Presentation(priority: .interactive, expanded: expanded, opensAt: .expanded, accepts: Self.acceptedKinds)
        case .dragOut:
            return Presentation(priority: .interactive, expanded: expanded, opensAt: .expanded)
        case .receiving:
            return Presentation(priority: .interactive, peek: peek, expanded: expanded, opensAt: .peek, accepts: Self.acceptedKinds)
        case .ambient:
            // Takes drops too, so a promise that outlives the grace period is
            // still kept while the shelf owns the notch.
            return Presentation(priority: .ambient, peek: peek, expanded: expanded, opensAt: .peek, accepts: Self.acceptedKinds)
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
