import AppKit
import SwiftUI

/// The dragging source of every drag-out. Owned by the block, not by a tile
/// view: the notch rebuilds its views when the presentation changes, which
/// happens as the drag starts, and the source must outlive that.
@MainActor
final class DragOutSource: NSObject, @preconcurrency NSDraggingSource {
    /// What the drag in progress carries.
    var target: ShelfTarget?
    private let onEnd: @MainActor (ShelfTarget, Bool) -> Void

    init(onEnd: @escaping @MainActor (ShelfTarget, Bool) -> Void) {
        self.onEnd = onEnd
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only, so Finder never moves a user's file. `.generic` because
        // some destinations take only that. Nothing inside this app: a drop
        // back on the notch ends with no operation and the item stays.
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard let target else { return }
        self.target = nil
        onEnd(target, !operation.isEmpty)
    }
}

/// One thing to put on the drag pasteboard, with its drag image.
struct DragPayload {
    let writer: any NSPasteboardWriting
    let image: NSImage
}

/// A context menu entry of a tile.
struct TileMenuItem {
    let title: String
    let perform: @MainActor () -> Void
}

/// Transparent AppKit layer over a tile: starts drag-outs, reports hover,
/// clicks and double-clicks, and shows the context menu.
///
/// AppKit, not SwiftUI `.onDrag`, for the drag-out operation result (an item
/// leaves the shelf only when the drop succeeded) and for first-mouse control:
/// the notch panel never becomes key, so the first click must act.
struct DragSourceView: NSViewRepresentable {
    let target: ShelfTarget
    let payloads: @MainActor () -> [DragPayload]
    let beginDragOut: @MainActor (ShelfTarget) -> DragOutSource?
    let menuItems: [TileMenuItem]
    let onClick: (@MainActor () -> Void)?
    let onDoubleClick: (@MainActor () -> Void)?
    let onHover: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> DragSourceNSView {
        let view = DragSourceNSView()
        view.config = self
        return view
    }

    func updateNSView(_ view: DragSourceNSView, context: Context) {
        view.config = self
    }
}

final class DragSourceNSView: NSView {
    var config: DragSourceView?
    private var mouseDownEvent: NSEvent?
    private var trackingArea: NSTrackingArea?

    private static let dragImageSide: CGFloat = 64

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // activeAlways: the panel is never key and the app rarely active.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { config?.onHover(true) }
    override func mouseExited(with event: NSEvent) { config?.onHover(false) }

    // MARK: Clicks and drag

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let config else { return }
        mouseDownEvent = nil // one session per press
        let payloads = config.payloads()
        guard !payloads.isEmpty, let source = config.beginDragOut(config.target) else { return }

        let side = Self.dragImageSide
        let origin = CGPoint(x: bounds.midX - side / 2, y: bounds.midY - side / 2)
        let items = payloads.enumerated().map { index, payload in
            let item = NSDraggingItem(pasteboardWriter: payload.writer)
            // Fan a stack out a little so it reads as several items.
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(CGRect(x: origin.x + offset, y: origin.y - offset, width: side, height: side),
                                  contents: payload.image)
            return item
        }
        let session = beginDraggingSession(with: items, event: down, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        if event.clickCount == 2 {
            config?.onDoubleClick?()
        } else if event.clickCount == 1 {
            config?.onClick?()
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let config, !config.menuItems.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in config.menuItems {
            let item = NSMenuItem(title: entry.title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(entry.perform)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.perform()
    }
}

/// Holds a menu entry's closure as an object, for `representedObject`.
@MainActor
private final class MenuAction: NSObject {
    let perform: @MainActor () -> Void
    init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
}
