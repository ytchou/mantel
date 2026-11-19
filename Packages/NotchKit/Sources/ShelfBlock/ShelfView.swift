import AppKit
import SwiftUI

/// The expanded shelf: a header with the count and Clear, and a horizontally
/// scrolling row of tiles. While a drag is in progress a dashed outline and
/// "Drop here" mark the drop target. Drops themselves are taken by the shell.
struct ShelfView: View {
    let store: ShelfStore
    let ui: ShelfBlock.UIState
    let actions: ShelfActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ZStack {
                if store.isEmpty {
                    emptyState
                } else {
                    tiles
                }
                if ui.isDropTarget { dropOverlay }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if let stack = expandedStack {
                Button {
                    ui.expandedStackID = nil
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Back to the shelf")
                Text("\(stack.items.count) items")
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Text("Shelf")
                    .font(.system(size: 13, weight: .semibold))
                if store.itemCount > 0 {
                    Text("\(store.itemCount)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .opacity(0.6)
                }
            }
            Spacer()
            if ui.isReceiving {
                ProgressView()
                    .controlSize(.small)
                    .help("Waiting for dropped files")
            }
            if !store.isEmpty {
                Button("Clear") { actions.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .opacity(0.75)
                    .help("Remove everything from the shelf")
            }
        }
    }

    // MARK: Content

    private var expandedStack: ShelfStack? {
        ui.expandedStackID.flatMap { store.stack($0) }
    }

    private var tiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                if let stack = expandedStack {
                    ForEach(stack.items) { item in
                        TileView(target: .item(item.id), items: [item], store: store, ui: ui, actions: actions)
                    }
                } else {
                    ForEach(store.stacks) { stack in
                        TileView(target: .stack(stack.id), items: stack.items, store: store, ui: ui, actions: actions)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26, weight: .light))
            Text("Drag files, links or text here to keep them")
                .font(.system(size: 12))
                .opacity(0.7)
        }
        .opacity(ui.isDropTarget ? 0 : 1)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            }
            .overlay {
                Label("Drop here", systemImage: "tray.and.arrow.down.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
            }
            .allowsHitTesting(false)
    }
}

/// One tile: a stack (with a count badge) or a single item.
struct TileView: View {
    let target: ShelfTarget
    let items: [ShelfItem]
    let store: ShelfStore
    let ui: ShelfBlock.UIState
    let actions: ShelfActions
    @State private var isHovering = false

    private static let width: CGFloat = 76
    private static let side: CGFloat = 64

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                if let first = items.first {
                    TilePreview(item: first, store: store, side: Self.side)
                }
                if items.count > 1 {
                    Text("\(items.count)")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white))
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: Self.side, height: Self.side)
            Text(title)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.width)
        }
        .frame(width: Self.width)
        .padding(.top, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.1 : 0))
        )
        .overlay {
            DragSourceView(
                target: target,
                payloads: { store.dragPayloads(for: target) },
                beginDragOut: actions.beginDragOut,
                menuItems: menuItems,
                onClick: clickAction,
                onDoubleClick: doubleClickAction,
                onHover: { isHovering = $0 }
            )
        }
        // Always shown, not only on hover: on hover alone it was easy to miss.
        .overlay(alignment: .topTrailing) {
            Button {
                actions.remove(target)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .white)
                    .opacity(isHovering ? 1 : 0.6)
            }
            .buttonStyle(.plain)
            .help("Remove from the shelf")
            .offset(x: 2, y: -2)
        }
        .help(title)
    }

    private var isStack: Bool { items.count > 1 }

    /// A click on a stack shows its items.
    private var clickAction: (@MainActor () -> Void)? {
        guard isStack else { return nil }
        return { toggleExpanded() }
    }

    /// A double-click previews the files.
    private var doubleClickAction: (@MainActor () -> Void)? {
        guard hasFiles else { return nil }
        let actions = self.actions
        let target = self.target
        return { actions.quickLook(target) }
    }

    private var hasFiles: Bool { items.contains(where: \.isFile) }

    private var title: String {
        guard let first = items.first else { return "" }
        return store.displayName(of: first)
    }

    private var menuItems: [TileMenuItem] {
        var entries: [TileMenuItem] = []
        if hasFiles {
            entries.append(TileMenuItem(title: "Quick Look") { actions.quickLook(target) })
        }
        if isStack {
            entries.append(TileMenuItem(title: "Show Items") { toggleExpanded() })
        }
        entries.append(TileMenuItem(title: isStack ? "Remove Stack" : "Remove") { actions.remove(target) })
        return entries
    }

    private func toggleExpanded() {
        guard case let .stack(id) = target else { return }
        ui.expandedStackID = ui.expandedStackID == id ? nil : id
    }
}

/// The picture of one item: a file thumbnail, a text preview, or a link's host.
struct TilePreview: View {
    let item: ShelfItem
    let store: ShelfStore
    let side: CGFloat

    var body: some View {
        switch item.content {
        case .file:
            if let url = store.fileURL(of: item) {
                FileThumbnail(url: url, side: side)
            } else {
                card { Image(systemName: "questionmark.square.dashed").font(.system(size: 22)) }
            }
        case let .link(url):
            card {
                VStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 18, weight: .medium))
                    Text(url.host() ?? url.absoluteString)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(4)
            }
        case let .text(text):
            card {
                Text(String(text.prefix(160)))
                    .font(.system(size: 8))
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.12))
            .overlay { content() }
            .frame(width: side, height: side)
    }
}

/// Beside the notch: a tray and the item count.
struct ShelfPeekView: View {
    let store: ShelfStore
    let ui: ShelfBlock.UIState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: store.isEmpty ? "tray.and.arrow.down" : "tray.full.fill")
            if !store.isEmpty {
                Text("\(store.itemCount)")
                    .monospacedDigit()
            }
            if ui.isReceiving {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shelf, \(store.itemCount) items")
    }
}

// MARK: - Store helpers for the views

extension ShelfStore {
    /// Name under a tile: the file name, a link's host, a text's first line.
    func displayName(of item: ShelfItem) -> String {
        switch item.content {
        case let .file(path, _, _):
            return (fileURL(of: item) ?? URL(filePath: path)).lastPathComponent
        case let .link(url):
            return url.host() ?? url.absoluteString
        case let .text(text):
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Pasteboard writers for a drag-out: file URLs, URLs and strings.
    func dragPayloads(for target: ShelfTarget) -> [DragPayload] {
        items(for: target).compactMap { item in
            switch item.content {
            case .file:
                guard let url = fileURL(of: item) else { return nil }
                let image = ThumbnailCache.shared.cached(for: url) ?? ThumbnailCache.shared.icon(for: url)
                return DragPayload(writer: url as NSURL, image: image)
            case let .link(url):
                return DragPayload(writer: url as NSURL, image: Self.symbol("link"))
            case let .text(text):
                return DragPayload(writer: text as NSString, image: Self.symbol("text.alignleft"))
            }
        }
    }

    private static func symbol(_ name: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
    }
}
