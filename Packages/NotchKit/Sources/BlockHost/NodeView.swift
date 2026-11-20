import AppKit
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
/// when a stack leaves them out. Looks and timings follow the in-app Shelf
/// and Rename views they replace.
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
        case let .vstack(children, spacing, alignment, padding, offset):
            VStack(alignment: horizontal(alignment), spacing: spacing.map { CGFloat($0) } ?? NotchStyle.spacing) {
                self.children(children)
            }
            .modifier(Inset(padding: padding))
            .offset(x: offset?.x ?? 0, y: offset?.y ?? 0)

        case let .hstack(children, spacing, alignment, padding, offset):
            HStack(alignment: vertical(alignment), spacing: spacing.map { CGFloat($0) } ?? NotchStyle.spacing) {
                self.children(children)
            }
            .modifier(Inset(padding: padding))
            .offset(x: offset?.x ?? 0, y: offset?.y ?? 0)

        case let .box(child, width, height, cornerRadius, fillOpacity, color, stroke):
            // Without a width or a height the box takes the child's size on
            // that axis; the child is centred.
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            view(child)
                .frame(width: width.map { CGFloat($0) }, height: height.map { CGFloat($0) })
                .background(shape.fill(Color(wire: color).opacity(fillOpacity)))
                .overlay {
                    if let stroke {
                        shape.strokeBorder(Color(wire: stroke.color), style: StrokeStyle(
                            lineWidth: stroke.width, dash: (stroke.dash ?? []).map { CGFloat($0) }
                        ))
                    }
                }

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

        case let .symbol(name, size, opacity, width, color, weight, secondaryColor):
            let image = Image(systemName: name).font(.system(size: size, weight: wireWeight(weight)))
            Group {
                if let secondaryColor {
                    image.symbolRenderingMode(.palette)
                        .foregroundStyle(Color(wire: color), Color(wire: secondaryColor))
                } else if let color {
                    image.foregroundStyle(Color(wire: color))
                } else {
                    image
                }
            }
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

        case let .progress(value, width, color, drainsOver, track):
            ProgressNode(value: value, width: width, color: color, drainsOver: drainsOver, track: track, model: model)
                // A new value or duration starts the bar again; the same one
                // sent again in a new tree keeps it draining.
                .id(drainsOver.map { [value, $0] } ?? [])

        case let .button(id, title, style, symbol, enabled, color, restOpacity, labelColor):
            ButtonNode(id: id, title: title, style: style ?? .capsule, symbol: symbol, enabled: enabled ?? true,
                       color: color, restOpacity: restOpacity, labelColor: labelColor, onButton: onButton)

        case let .spacer(minLength):
            Spacer(minLength: minLength.map { CGFloat($0) })

        // Contract version 2.

        case let .zstack(children, alignment):
            ZStack(alignment: swiftUI(alignment)) {
                self.children(children)
            }

        case let .scroll(axis, child):
            ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
                view(child)
            }

        case let .styledText(runs, attributes):
            styledText(runs, attributes)

        case let .capsule(child, fill, padding, height):
            view(child)
                .modifier(Inset(padding: padding))
                .frame(height: height.map { CGFloat($0) })
                .background(Capsule().fill(fill.map { Color(wire: $0) } ?? .white.opacity(0.12)))

        case let .spinner(size):
            ProgressView()
                .controlSize(size == .mini ? .mini : .small)

        case let .sweep(color):
            SweepLine(color: Color(wire: color), model: model)

        case let .frame(child, width, height, fill, alignment):
            let placement = swiftUI(alignment)
            view(child)
                .frame(width: width.map { CGFloat($0) }, height: height.map { CGFloat($0) }, alignment: placement)
                .frame(maxWidth: fill == .width || fill == .both ? .infinity : nil,
                       maxHeight: fill == .height || fill == .both ? .infinity : nil,
                       alignment: placement)

        case let .item(id, child, hoverFill, cornerRadius, drag, menu, click, doubleClick, help):
            ItemNode(id: id, child: child, hoverFill: hoverFill, cornerRadius: cornerRadius, drag: drag,
                     menu: menu ?? [], click: click == true, doubleClick: doubleClick == true, help: help,
                     model: model, onButton: onButton)
        }
    }

    private func view(_ child: ViewNode) -> AnyView {
        AnyView(NodeView(node: child, model: model, onButton: onButton))
    }

    private func children(_ nodes: [ViewNode]) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
            view(child)
        }
    }

    /// Text runs in one `Text`, each run struck through on its own. Nil
    /// attributes: 12 pt, regular, the inherited white, opaque, one line,
    /// truncated at the end.
    private func styledText(_ runs: [ViewNode.TextRun], _ attributes: ViewNode.TextAttributes) -> some View {
        var string = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            if run.strikethrough == true { part.strikethroughStyle = .single }
            string += part
        }
        let font = Font.system(size: attributes.size ?? 12, weight: wireWeight(attributes.weight))
        return Text(string)
            .font(attributes.monospacedDigits == true ? font.monospacedDigit() : font)
            .foregroundStyle(attributes.color.map { AnyShapeStyle(Color(wire: $0)) } ?? AnyShapeStyle(.foreground))
            .opacity(attributes.opacity ?? 1)
            .lineLimit(attributes.lineLimit ?? 1)
            .truncationMode(attributes.truncation == .middle ? .middle : .tail)
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

    private func swiftUI(_ alignment: ViewNode.Alignment?) -> Alignment {
        switch alignment {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .leading: .leading
        case .center, nil: .center
        case .trailing: .trailing
        case .bottomLeading: .bottomLeading
        case .bottom: .bottom
        case .bottomTrailing: .bottomTrailing
        }
    }
}

private func wireWeight(_ weight: ViewNode.FontWeight?) -> Font.Weight {
    switch weight {
    case .ultraLight: .ultraLight
    case .thin: .thin
    case .light: .light
    case .regular, nil: .regular
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    case .heavy: .heavy
    case .black: .black
    }
}

/// A stack's or a capsule's padding from the wire.
private struct Inset: ViewModifier {
    let padding: ViewNode.Insets?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, padding?.horizontal ?? 0)
            .padding(.vertical, padding?.vertical ?? 0)
    }
}

// MARK: - Colours

extension Color {
    /// A wire colour; white when nil or when the hex string is not `#RRGGBB`.
    init(wire: WireColor?) {
        guard let wire, let rgb = wire.rgb else {
            self = Color.white.opacity(wire?.opacity ?? 1)
            return
        }
        self = Color(red: rgb.red, green: rgb.green, blue: rgb.blue).opacity(wire.opacity ?? 1)
    }
}

extension WireColor {
    /// The red, green and blue parts from 0 to 1, or nil when `hex` is not
    /// `#RRGGBB` (the `#` is optional).
    var rgb: (red: Double, green: Double, blue: Double)? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

// MARK: - Progress

/// A thin capsule bar filled from the left. Without a width it fills the
/// width it is given, and is 5 pt high or less when given less. With
/// `drainsOver` it empties linearly over that many seconds, as Rename's Undo
/// bar did; still with Reduce Motion.
///
/// Shortcut, as in the in-app Undo bar: a new view (a hover, a new
/// presentation) drains again from `value`; the block is not told the time
/// left. Fix by sending the remaining time if that proves confusing.
private struct ProgressNode: View {
    let value: Double
    let width: Double?
    let color: WireColor?
    let drainsOver: Double?
    /// The unfilled bar; white at 0.2 when nil.
    let track: WireColor?
    let model: RemoteModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var drained = false

    private static let height: CGFloat = 5

    var body: some View {
        Group {
            if let width {
                bar(width: width, height: Self.height)
            } else {
                GeometryReader { proxy in
                    bar(width: proxy.size.width, height: min(Self.height, proxy.size.height))
                }
                .frame(maxHeight: Self.height)
            }
        }
        .onAppear {
            guard let drainsOver, model.animates(systemReduceMotion: systemReduceMotion) else { return }
            withAnimation(.linear(duration: drainsOver)) { drained = true }
        }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        let fraction = drained ? 0 : min(max(value, 0), 1)
        return Capsule()
            .fill(track.map { Color(wire: $0) } ?? .white.opacity(0.2))
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule().fill(Color(wire: color)).frame(width: width * fraction, height: height)
            }
    }
}

// MARK: - Sweep

/// A 2 pt line that sweeps up and down its container, as Rename's scan line
/// did: 0.8 s ease in and out, repeating. With Reduce Motion it stays in the
/// middle.
private struct SweepLine: View {
    let color: Color
    let model: RemoteModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var atBottom = false

    var body: some View {
        let animates = model.animates(systemReduceMotion: systemReduceMotion)
        GeometryReader { proxy in
            Rectangle()
                .fill(color)
                .frame(height: 2)
                .shadow(color: color, radius: 3)
                .offset(y: animates ? (atBottom ? proxy.size.height - 4 : 2) : proxy.size.height / 2)
        }
        .onAppear {
            guard animates else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { atBottom = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Button

/// A button from the wire. A disabled button is drawn at 0.4; `restOpacity`
/// applies while the pointer is not on it.
private struct ButtonNode: View {
    let id: String
    let title: String
    let style: ViewNode.ButtonStyle
    let symbol: String?
    let enabled: Bool
    let color: WireColor?
    let restOpacity: Double?
    let labelColor: WireColor?
    let onButton: @MainActor (String) -> Void
    @State private var isHovering = false

    var body: some View {
        Button { onButton(id) } label: { label }
            .buttonStyle(WireButtonStyle(style: style, color: color, labelColor: labelColor))
            .disabled(!enabled)
            .opacity(enabled ? (isHovering ? 1 : restOpacity ?? 1) : 0.4)
            .onHover { isHovering = $0 }
    }

    /// The title is always the button's label: a plain button with a symbol
    /// shows the symbol only, and VoiceOver reads the title.
    @ViewBuilder private var label: some View {
        if let symbol {
            if style == .plain {
                Label(title, systemImage: symbol).labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
            }
        } else {
            Text(title)
        }
    }
}

private struct WireButtonStyle: ButtonStyle {
    let style: ViewNode.ButtonStyle
    let color: WireColor?
    /// The label colour of an `accent` button; nil derives it from `color`.
    let labelColor: WireColor?

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        switch style {
        case .capsule:
            NotchCapsuleButtonStyle(tint: Color(wire: color)).makeBody(configuration: configuration)
        case .accent:
            // As Rename's Undo: 12 pt semibold on the accent, dimmer while pressed.
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(onAccent)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(accent.opacity(configuration.isPressed ? 0.8 : 1)))
                .contentShape(Capsule())
        case .plain:
            configuration.label
                .font(NotchStyle.body)
                .foregroundStyle(color.map { AnyShapeStyle(Color(wire: $0)) } ?? AnyShapeStyle(.foreground))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
        }
    }

    private var accent: Color {
        color.map { Color(wire: $0) } ?? .accentColor
    }

    /// Text on the accent: the accent at 17% brightness, which gives
    /// Rename's dark amber on its amber. White on the system accent.
    private var onAccent: Color {
        if let labelColor { return Color(wire: labelColor) }
        guard let rgb = color?.rgb else { return .white }
        return Color(red: rgb.red * 0.17, green: rgb.green * 0.17, blue: rgb.blue * 0.17)
    }
}

// MARK: - Item

/// An `item`: the child with a hover fill (white at 0.1 unless the block
/// gives one) drawn by the app, under the AppKit layer that takes drags,
/// clicks and the context menu.
private struct ItemNode: View {
    let id: String
    let child: ViewNode
    let hoverFill: WireColor?
    let cornerRadius: Double?
    let drag: ViewNode.ItemDrag?
    let menu: [ActionItem]
    let click: Bool
    let doubleClick: Bool
    let help: String?
    let model: RemoteModel
    let onButton: @MainActor (String) -> Void
    @State private var isHovering = false

    var body: some View {
        let fill = hoverFill.map { Color(wire: $0) } ?? .white.opacity(0.1)
        AnyView(NodeView(node: child, model: model, onButton: onButton))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius ?? 10, style: .continuous)
                    .fill(fill.opacity(isHovering ? 1 : 0))
            )
            .overlay {
                ItemLayer(id: id, model: model, drag: drag, menu: menu, click: click,
                          doubleClick: doubleClick, onHover: { isHovering = $0 })
            }
            .modifier(Help(text: help))
    }
}

private struct Help: ViewModifier {
    let text: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
