import AppKit
import NotchCore

/// The panel's content view: the drop destination for the notch.
///
/// AppKit dragging, not SwiftUI `.onDrop`: it gives first-class file promises
/// and the raw pasteboard (decision from the drag spike). The SwiftUI hosting
/// view is a subview; it registers no dragged types, so drags reach this view.
final class DropTargetView: NSView {
    /// Kinds the current presentation takes. Empty takes no drop.
    var acceptedKinds: () -> Set<DropKind> = { [] }
    /// Called once per drop with every accepted item, after promises resolve.
    var onDrop: ([DroppedItem]) -> Void = { _ in }

    /// Kinds on the pasteboard of the drag in progress, read once on entry.
    private var dragKinds: Set<DropKind> = []

    private static let readClasses: [AnyClass] = [NSFilePromiseReceiver.self, NSURL.self, NSString.self]
    private static let dropRoot = FileManager.default.temporaryDirectory
        .appending(path: "TopNotch/Drops", directoryHint: .isDirectory)

    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "TopNotch.promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // File URLs cover files and folders, .URL web links, .string text;
        // readableDraggedTypes covers file promises.
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let objects = sender.draggingPasteboard.readObjects(forClasses: Self.readClasses, options: nil) ?? []
        dragKinds = Set(objects.compactMap { Self.kind(of: $0) })
        return operation()
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation() }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dragKinds = [] }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { operation() != [] }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let accepted = acceptedKinds()
        let drop = PendingDrop(deliver: onDrop)
        let directory = Self.dropRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        // Promise first: image drags can carry a promise and a URL on the same
        // item, and the file is what is wanted. Each item is read as the first
        // class that can read it.
        sender.enumerateDraggingItems(options: [], for: self, classes: Self.readClasses, searchOptions: [:]) { draggingItem, _, _ in
            guard let kind = Self.kind(of: draggingItem.item), accepted.contains(kind) else { return }
            if let receiver = draggingItem.item as? NSFilePromiseReceiver {
                self.receive(receiver, into: directory, for: drop)
            } else if let item = Self.item(from: draggingItem.item) {
                drop.add(item)
            }
        }
        dragKinds = []
        return drop.finishEnumerating()
    }

    // MARK: Items

    private func operation() -> NSDragOperation {
        let accepted = acceptedKinds()
        return accepted.isDisjoint(with: dragKinds) ? [] : .copy
    }

    private static func kind(of object: Any) -> DropKind? {
        if object is NSFilePromiseReceiver { return .file }
        return item(from: object)?.kind
    }

    private static func item(from object: Any) -> DroppedItem? {
        if let url = object as? URL { return url.isFileURL ? .file(url) : .link(url) }
        if let text = object as? String { return .text(text) }
        return nil
    }

    private func receive(_ receiver: NSFilePromiseReceiver, into directory: URL, for drop: PendingDrop) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return
        }
        // The reader is called once per promised file, after the source wrote it.
        // Assumes `fileTypes` lists one entry per file; a source that calls back
        // fewer times would hold the drop open.
        drop.expect(max(receiver.fileTypes.count, 1))
        receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: promiseQueue) { @Sendable url, error in
            Task { @MainActor in
                drop.promiseFinished(error == nil ? .file(url) : nil)
            }
        }
    }
}

/// Collects the items of one drop and delivers them once, after every promise
/// has been written or has failed. Failed promises are left out.
@MainActor
private final class PendingDrop {
    private var items: [DroppedItem] = []
    private var waiting = 0
    private var enumerating = true
    private var delivered = false
    private let deliver: ([DroppedItem]) -> Void

    init(deliver: @escaping ([DroppedItem]) -> Void) { self.deliver = deliver }

    func add(_ item: DroppedItem) { items.append(item) }

    func expect(_ count: Int) { waiting += count }

    func promiseFinished(_ item: DroppedItem?) {
        if let item { items.append(item) }
        waiting -= 1
        deliverIfDone()
    }

    /// Returns whether anything was or may still be delivered.
    func finishEnumerating() -> Bool {
        enumerating = false
        let any = !items.isEmpty || waiting > 0
        deliverIfDone()
        return any
    }

    private func deliverIfDone() {
        guard !enumerating, waiting <= 0, !delivered else { return }
        delivered = true
        if !items.isEmpty { deliver(items) }
    }
}
