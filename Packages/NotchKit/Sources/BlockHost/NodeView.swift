import BlockWire
import NotchCore
import SwiftUI

/// Draws the tree a block process sent for one slot, filling the content
/// area white on black, as the shell expects of a block's view.
public struct RemoteSlotView: View {
    let model: RemoteModel
    let slot: RemoteSlot
    var onButton: @MainActor (String) -> Void = { _ in }

    public var body: some View {
        Group {
            if let tree = model.tree(for: slot) {
                NodeView(node: tree, model: model, onButton: onButton)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }
}

/// Draws one `ViewNode` and its children. Fonts come from `NotchStyle`;
/// sizes, spacing and padding come from the node, with `NotchStyle` values
/// when a stack leaves them out.
public struct NodeView: View {
    let node: ViewNode
    let model: RemoteModel
    var onButton: @MainActor (String) -> Void = { _ in }

    public var body: some View {
        if let label = node.accessibilityLabel {
            content.accessibilityLabel(label)
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case let .vstack(children, spacing, alignment, padding):
            VStack(alignment: horizontal(alignment), spacing: spacing.map { CGFloat($0) } ?? NotchStyle.spacing) {
                self.children(children)
            }
            .modifier(Inset(padding: padding))

        case let .hstack(children, spacing, alignment, padding):
            HStack(alignment: vertical(alignment), spacing: spacing.map { CGFloat($0) } ?? NotchStyle.spacing) {
                self.children(children)
            }
            .modifier(Inset(padding: padding))

        case let .box(child, width, height, cornerRadius, fillOpacity):
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(fillOpacity))
                .frame(width: width, height: height)
                .overlay(AnyView(NodeView(node: child, model: model, onButton: onButton)))

        case let .text(text, style):
            switch style {
            case .title:
                Text(text).font(NotchStyle.title).lineLimit(1).truncationMode(.tail)
            case .body:
                Text(text).font(NotchStyle.body).lineLimit(1).truncationMode(.tail)
            case .secondary:
                Text(text).font(NotchStyle.secondary).opacity(NotchStyle.secondaryOpacity)
                    .lineLimit(1).truncationMode(.tail)
            }

        case let .symbol(name, size, opacity, width):
            Image(systemName: name)
                .font(.system(size: size))
                .opacity(opacity ?? 1)
                .frame(width: width.map { CGFloat($0) })

        case let .image(asset, size, cornerRadius):
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if let image = model.image(asset) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                // The image never arrived or was evicted: draw the artwork
                // placeholder, as the in-app blocks do.
                shape
                    .fill(.white.opacity(0.12))
                    .frame(width: size, height: size)
            }

        case let .progress(value, width):
            let fraction = min(max(value, 0), 1)
            Capsule()
                .fill(.white.opacity(0.2))
                .frame(width: width, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: width * fraction, height: 5)
                }

        case let .button(id, title):
            Button(title) { onButton(id) }
                .buttonStyle(.notchCapsule)

        case let .spacer(minLength):
            Spacer(minLength: minLength.map { CGFloat($0) })
        }
    }

    private func children(_ nodes: [ViewNode]) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
            AnyView(NodeView(node: child, model: model, onButton: onButton))
        }
    }

    private func horizontal(_ alignment: ViewNode.StackAlignment?) -> HorizontalAlignment {
        switch alignment {
        case .start: .leading
        case .end: .trailing
        case .center, nil: .center
        }
    }

    private func vertical(_ alignment: ViewNode.StackAlignment?) -> VerticalAlignment {
        switch alignment {
        case .start: .top
        case .end: .bottom
        case .center, nil: .center
        }
    }
}

/// A stack's padding from the wire.
private struct Inset: ViewModifier {
    let padding: ViewNode.Insets?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, padding?.horizontal ?? 0)
            .padding(.vertical, padding?.vertical ?? 0)
    }
}
