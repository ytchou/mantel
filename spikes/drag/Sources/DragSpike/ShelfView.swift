import AppKit

/// Drop destination for the shelf.
///
/// Why AppKit NSDraggingDestination instead of SwiftUI .onDrop / .dropDestination:
///   - we see draggingEntered/Updated/Exited/ended individually and can log each phase;
///   - we can inspect the raw NSPasteboard types of every item (needed to learn what Safari,
///     Photos, Finder, TextEdit actually put on the pasteboard);
///   - NSFilePromiseReceiver is first-class here; SwiftUI only exposes promises indirectly via
///     NSItemProvider / Transferable, which hides which representation was chosen;
///   - acceptsFirstMouse / hitTest control on a non-activating panel is direct.
final class ShelfView: NSView {
    var onItemAdded: ((ShelfItem) -> Void)?

    private let stack = NSStackView()
    private let hint = NSTextField(labelWithString: "Drop files, folders, links, text here")
    private var highlightReason: String?
    private var dropHover = false

    /// Promised files land here: $TMPDIR/DragSpike/promises/<uuid>/
    let promiseRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("DragSpike/promises", isDirectory: true)
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "DragSpike.promises"
        q.qualityOfService = .userInitiated
        return q
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 2
        updateAppearance()

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        // File URLs cover files and folders. .URL covers web links (Safari address bar).
        // .string covers plain text. readableDraggedTypes covers file promises
        // (com.apple.NSFilePromiseItemMetaData, com.apple.pasteboard.promised-file-url, etc.).
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    required init?(coder: NSCoder) { fatalError() }

    // The panel can never become key, so the first click must be accepted directly.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSessionHighlight(_ on: Bool, reason: String) {
        highlightReason = on ? reason : nil
        updateAppearance()
    }

    private func updateAppearance() {
        if dropHover {
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.35).cgColor
            layer?.borderColor = NSColor.systemGreen.cgColor
        } else if highlightReason != nil {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
            layer?.borderColor = NSColor.systemBlue.cgColor
        } else {
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
            layer?.borderColor = NSColor.darkGray.cgColor
        }
    }

    func addChip(for item: ShelfItem) {
        hint.isHidden = true
        let chip = ChipView(item: item)
        stack.addArrangedSubview(chip)
        // Spike: no scrolling. Keep the last 5 chips so the row fits in 360 pt.
        while stack.arrangedSubviews.count > 5, let first = stack.arrangedSubviews.first {
            stack.removeArrangedSubview(first)
            first.removeFromSuperview()
        }
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHover = true
        updateAppearance()
        let pb = sender.draggingPasteboard
        Log.line("DROP", "draggingEntered sourceMask=\(sender.draggingSourceOperationMask.rawValue) items=\(pb.pasteboardItems?.count ?? 0) types=\(pb.types?.map(\.rawValue) ?? [])")
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHover = false
        updateAppearance()
        Log.line("DROP", "draggingExited")
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHover = false
        updateAppearance()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let pbItems = pb.pasteboardItems ?? []
        Log.line("DROP", "performDragOperation items=\(pbItems.count)")
        for (i, it) in pbItems.enumerated() {
            Log.line("DROP", "  item[\(i)] types=\(it.types.map(\.rawValue))")
        }

        // Class priority per item: promise first (Photos / Safari images put a promise AND
        // sometimes a URL on the same item; we want the actual file), then URL (file or web),
        // then plain string. enumerateDraggingItems yields the first class that can read
        // each item, so each dragged item produces exactly one chip.
        var handled = 0
        sender.enumerateDraggingItems(
            options: [],
            for: self,
            classes: [NSFilePromiseReceiver.self, NSURL.self, NSString.self],
            searchOptions: [:]
        ) { [weak self] draggingItem, index, _ in
            guard let self else { return }
            let types = index < pbItems.count ? pbItems[index].types.map(\.rawValue) : []
            switch draggingItem.item {
            case let receiver as NSFilePromiseReceiver:
                handled += 1
                self.receivePromise(receiver, index: index, types: types)
            case let url as URL:
                handled += 1
                self.accept(url: url, types: types)
            case let url as NSURL:
                handled += 1
                self.accept(url: url as URL, types: types)
            case let s as String:
                handled += 1
                self.accept(text: s, types: types)
            case let s as NSString:
                handled += 1
                self.accept(text: s as String, types: types)
            default:
                Log.line("DROP", "  item[\(index)] unreadable object=\(type(of: draggingItem.item)) types=\(types)")
            }
        }
        Log.line("DROP", "performDragOperation handled=\(handled)")
        return handled > 0
    }

    // MARK: Item handling

    private func accept(url: URL, types: [String]) {
        let item: ShelfItem
        if url.isFileURL {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
            item = ShelfItem(kind: isDir ? .folder : .file, fileURL: url, link: nil, text: nil)
        } else {
            item = ShelfItem(kind: .link, fileURL: nil, link: url, text: nil)
        }
        add(item, types: types)
    }

    private func accept(text: String, types: [String]) {
        add(ShelfItem(kind: .text, fileURL: nil, link: nil, text: text), types: types)
    }

    private func receivePromise(_ receiver: NSFilePromiseReceiver, index: Int, types: [String]) {
        let dest = promiseRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            Log.line("PROMISE", "item[\(index)] cannot create \(dest.path): \(error)")
            return
        }
        let requestedAt = Date()
        Log.line("PROMISE", "item[\(index)] receiving fileTypes=\(receiver.fileTypes) into=\(dest.path)")
        // The reader block runs on promiseQueue once the source has finished writing the file.
        receiver.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
            let ms = String(format: "%.0fms", Date().timeIntervalSince(requestedAt) * 1000)
            DispatchQueue.main.async {
                if let error {
                    Log.line("PROMISE", "item[\(index)] FAILED after \(ms): \(error)")
                    return
                }
                Log.line("PROMISE", "item[\(index)] received after \(ms) url=\(url.path)")
                self?.add(ShelfItem(kind: .promisedFile, fileURL: url, link: nil, text: nil), types: types)
            }
        }
    }

    private func add(_ item: ShelfItem, types: [String]) {
        Log.line("DROP", "ACCEPTED kind=\(item.kind.rawValue) value=\(item.displayValue.debugDescription) types=\(types)")
        addChip(for: item)
        onItemAdded?(item)
    }
}
