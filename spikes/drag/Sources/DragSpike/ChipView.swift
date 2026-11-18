import AppKit

/// One shelf item. Acts as an NSDraggingSource so it can be dragged back out.
///
/// Non-activating panel notes (what is needed for mouse-down to reach this view while
/// another app is frontmost and the panel never becomes key):
///   1. acceptsFirstMouse(for:) -> true. Without it AppKit treats the first click on a
///      non-key window as "activate the window" and swallows it.
///   2. hitTest returns self for the whole chip so the label subview does not eat mouseDown.
///   3. The panel sets hidesOnDeactivate = false (NSPanel default is true, and an .accessory
///      app is almost never active) and ignoresMouseEvents = false.
///   4. The .nonactivatingPanel style mask lets the click be handled without activating the app.
final class ChipView: NSView, NSDraggingSource {
    let item: ShelfItem
    private var mouseDownEvent: NSEvent?
    private var dragStartedAt: Date?

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = color.withAlphaComponent(0.5).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalToConstant: 64),
        ])

        let kind = NSTextField(labelWithString: item.kind.rawValue)
        kind.font = .systemFont(ofSize: 9, weight: .semibold)
        kind.textColor = .white
        let title = NSTextField(labelWithString: item.shortTitle)
        title.font = .systemFont(ofSize: 9)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 2
        let v = NSStackView(views: [kind, title])
        v.orientation = .vertical
        v.spacing = 2
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: centerXAnchor),
            v.centerYAnchor.constraint(equalTo: centerYAnchor),
            v.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -6),
        ])
        toolTip = "\(item.kind.rawValue): \(item.displayValue)"
    }

    required init?(coder: NSCoder) { fatalError() }

    private var color: NSColor {
        switch item.kind {
        case .file: return .systemBlue
        case .folder: return .systemTeal
        case .link: return .systemPurple
        case .text: return .systemOrange
        case .promisedFile: return .systemPink
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point is in superview coordinates.
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        Log.line("CHIP", "mouseDown kind=\(item.kind.rawValue) appActive=\(NSApp.isActive) windowKey=\(window?.isKeyWindow ?? false)")
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        mouseDownEvent = nil // start one session per press

        guard let writer = pasteboardWriter() else {
            Log.line("DRAGOUT", "no pasteboard writer for kind=\(item.kind.rawValue)")
            return
        }
        let dragItem = NSDraggingItem(pasteboardWriter: writer)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    /// file URL for files, folders and received promised files; URL for links; string for text.
    private func pasteboardWriter() -> NSPasteboardWriting? {
        switch item.kind {
        case .file, .folder, .promisedFile: return item.fileURL as NSURL?
        case .link: return item.link as NSURL?
        case .text: return item.text as NSString?
        }
    }

    private func snapshot() -> NSImage {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)
        let img = NSImage(size: bounds.size)
        if let rep {
            cacheDisplay(in: bounds, to: rep)
            img.addRepresentation(rep)
        }
        return img
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only: Finder would otherwise MOVE a same-volume file out of its original location.
        // .generic is included because some destinations only accept generic.
        // Shelf-within-shelf drags are a no-op (copy into own app not meaningful here).
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        dragStartedAt = Date()
        Log.line("DRAGOUT", String(format: "BEGIN kind=%@ value=%@ at=(%.0f,%.0f)",
                                   item.kind.rawValue, item.displayValue.debugDescription,
                                   screenPoint.x, screenPoint.y))
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        let ms = dragStartedAt.map { String(format: "%.0fms", Date().timeIntervalSince($0) * 1000) } ?? "n/a"
        Log.line("DRAGOUT", String(format: "END kind=%@ operation=%@ (raw %lu) at=(%.0f,%.0f) duration=%@",
                                   item.kind.rawValue, Self.describe(operation), operation.rawValue,
                                   screenPoint.x, screenPoint.y, ms))
    }

    static func describe(_ op: NSDragOperation) -> String {
        if op.isEmpty { return "none" }
        var parts: [String] = []
        if op.contains(.copy) { parts.append("copy") }
        if op.contains(.link) { parts.append("link") }
        if op.contains(.generic) { parts.append("generic") }
        if op.contains(.private) { parts.append("private") }
        if op.contains(.move) { parts.append("move") }
        if op.contains(.delete) { parts.append("delete") }
        return parts.joined(separator: "|")
    }
}
