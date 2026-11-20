import AppKit
import BlockWire
import SwiftUI

/// The dragging source of every `item` drag-out. Held by `RemoteModel`, not
/// by a view: the notch rebuilds its views when the presentation changes,
/// which happens as the drag starts, and the source must outlive that.
@MainActor
final class ItemDragSource: NSObject, NSDraggingSource {
    /// The item whose drag is in progress.
    private(set) var itemID: String?
    /// Called once per drag: the item id, and true when it ended with an operation.
    var onEnd: @MainActor (String, Bool) -> Void = { _, _ in }

    func begin(_ id: String) {
        itemID = id
    }

    /// Copy only, so Finder never moves a user's file. `.generic` because
    /// some destinations take only that. Nothing inside this app: a drop
    /// back on the notch ends with no operation and the item stays.
    static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operationMask(for: context)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        end(operation: operation)
    }

    /// Reports the end of the drag in progress, if any.
    func end(operation: NSDragOperation) {
        guard let itemID else { return }
        self.itemID = nil
        onEnd(itemID, !operation.isEmpty)
    }

    /// The pasteboard writer of one drag entry: a file URL, a URL or a
    /// string. Nil for a link that is not a URL.
    static func writer(for drop: WireDrop) -> (any NSPasteboardWriting)? {
        switch drop {
        case let .file(path): URL(filePath: path) as NSURL
        case let .link(url): URL(string: url).map { $0 as NSURL }
        case let .text(string): string as NSString
        }
    }
}

/// One thing to put on the drag pasteboard, with its drag image.
struct ItemDragPayload {
    let writer: any NSPasteboardWriting
    let image: NSImage
}

extension RemoteModel {
    /// Pasteboard writers for a drag-out, each with the drag's image asset,
    /// or a file icon or symbol when the asset is missing. A file that
    /// `mayDragFile` refuses is left out.
    func dragPayloads(for drag: ViewNode.ItemDrag) -> [ItemDragPayload] {
        let asset = drag.image.flatMap { image($0) }
        return drag.items.compactMap { drop in
            if case let .file(path) = drop, !mayDragFile(path) { return nil }
            guard let writer = ItemDragSource.writer(for: drop) else { return nil }
            return ItemDragPayload(writer: writer, image: asset ?? Self.fallbackImage(for: drop))
        }
    }

    private static func fallbackImage(for drop: WireDrop) -> NSImage {
        switch drop {
        case let .file(path): NSWorkspace.shared.icon(forFile: path)
        case .link: symbol("link")
        case .text: symbol("text.alignleft")
        }
    }

    private static func symbol(_ name: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
    }
}

/// Transparent AppKit layer over an `item`: starts drag-outs, reports hover,
/// clicks and double-clicks, and shows the context menu. Answers go to the
/// model's callbacks with the item's id.
///
/// AppKit, not SwiftUI `.onDrag`, for the drag-out operation result (the
/// block learns whether the drop succeeded) and for first-mouse control:
/// the notch panel never becomes key, so the first click must act.
struct ItemLayer: NSViewRepresentable {
    let id: String
    let model: RemoteModel
    let drag: ViewNode.ItemDrag?
    let menu: [ActionItem]
    /// Send clicks; a block that did not ask for them gets none.
    let click: Bool
    /// Send double-clicks.
    let doubleClick: Bool
    let onHover: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ItemLayerNSView {
        let view = ItemLayerNSView()
        view.config = self
        return view
    }

    func updateNSView(_ view: ItemLayerNSView, context: Context) {
        view.config = self
    }
}

final class ItemLayerNSView: NSView {
    var config: ItemLayer?
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
        // Cleared on any drag, before the drag guard: a press that moves is
        // never a click, even on an item that cannot be dragged out.
        guard let down = mouseDownEvent else { return }
        mouseDownEvent = nil // one session per press
        guard let config, let drag = config.drag else { return }
        let payloads = config.model.dragPayloads(for: drag)
        guard !payloads.isEmpty else { return }
        let source = config.model.beginItemDrag(config.id)

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
        handleClick(count: event.clickCount)
    }

    /// Sends a click or a double-click, when the item asked for it.
    func handleClick(count: Int) {
        guard let config else { return }
        if count == 2, config.doubleClick {
            config.model.onItemAction(config.id, .doubleClick)
        } else if count == 1, config.click {
            config.model.onItemAction(config.id, .click)
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu()
    }

    func makeMenu() -> NSMenu? {
        guard let config, !config.menu.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in config.menu {
            let item = NSMenuItem(title: entry.title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.isEnabled = entry.enabled
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
        guard let config, let entryID = sender.representedObject as? String else { return }
        config.model.onItemAction(config.id, .menu(id: entryID))
    }
}
