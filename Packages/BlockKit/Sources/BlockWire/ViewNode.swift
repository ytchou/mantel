import Foundation

/// One element of a block's view, sent as data. The app draws it.
///
/// Contract version 2 adds kinds and optional fields; a nil field is not
/// encoded, so a tree built with version 1 fields encodes as in version 1.
///
/// Every node may carry an accessibility label; the app applies it as the
/// element's label for VoiceOver.
public struct ViewNode: Codable, Hashable, Sendable {
    public var kind: Kind
    public var accessibilityLabel: String?

    public init(_ kind: Kind, accessibilityLabel: String? = nil) {
        self.kind = kind
        self.accessibilityLabel = accessibilityLabel
    }

    public indirect enum Kind: Codable, Hashable, Sendable {
        /// Children top to bottom. `offset` moves the stack after layout.
        case vstack(children: [ViewNode], spacing: Double?, alignment: StackAlignment?, padding: Insets?, offset: Offset? = nil)
        /// Children left to right. `offset` moves the stack after layout.
        case hstack(children: [ViewNode], spacing: Double?, alignment: StackAlignment?, padding: Insets?, offset: Offset? = nil)
        /// A rounded rectangle filled with `color` (white when nil) at
        /// `fillOpacity`, with one child centred on it. Without a width or a
        /// height it takes the child's size on that axis. `stroke` outlines it.
        case box(child: ViewNode, width: Double?, height: Double?, cornerRadius: Double, fillOpacity: Double, color: WireColor? = nil, stroke: Stroke? = nil)
        /// One line of text, truncated at the end.
        case text(text: String, style: TextStyle)
        /// An SF Symbol. `width` fixes the frame width so a changing symbol
        /// does not move its neighbours. `secondaryColor` is used by
        /// palette symbols.
        case symbol(name: String, size: Double, opacity: Double?, width: Double?, color: WireColor? = nil, weight: FontWeight? = nil, secondaryColor: WireColor? = nil)
        /// An image sent earlier with `asset`, square, filled and clipped.
        case image(asset: String, size: Double, cornerRadius: Double)
        /// A thin capsule bar, filled from the left by `value` (0 to 1).
        /// Without a width it fills the space it is given. With
        /// `drainsOver`, the bar empties from `value` to 0 over that many
        /// seconds (still with Reduce Motion). `track` colours the unfilled
        /// bar (white at 0.2 when nil).
        case progress(value: Double, width: Double?, color: WireColor? = nil, drainsOver: Double? = nil, track: WireColor? = nil)
        /// A button. A click sends `input` with `button(id)`. `restOpacity`
        /// is its opacity while the pointer is not on it. `labelColor`
        /// colours the title and symbol of an `accent` button.
        case button(id: String, title: String, style: ButtonStyle? = nil, symbol: String? = nil, enabled: Bool? = nil, color: WireColor? = nil, restOpacity: Double? = nil, labelColor: WireColor? = nil)
        /// Flexible space.
        case spacer(minLength: Double?)

        // Contract version 2.

        /// Children on top of each other, first at the back.
        case zstack(children: [ViewNode], alignment: Alignment?)
        /// A scrolling area with no indicators.
        case scroll(axis: Axis, child: ViewNode)
        /// Text made of runs that share `attributes`.
        case styledText(runs: [TextRun], attributes: TextAttributes)
        /// A capsule filled with `fill` behind its child.
        case capsule(child: ViewNode, fill: WireColor?, padding: Insets?, height: Double?)
        /// Indeterminate progress.
        case spinner(size: SpinnerSize)
        /// A 2 pt line that moves up and down its container; still with
        /// Reduce Motion.
        case sweep(color: WireColor)
        /// A fixed size, or one that fills the space given on `fill`'s axes,
        /// with the child placed at `alignment` (centre when nil).
        case frame(child: ViewNode, width: Double?, height: Double?, fill: FrameFill?, alignment: Alignment?)
        /// One interactive element drawn and handled by the app: hover
        /// highlight, drag-out of `drag`, a context `menu`, click and
        /// double-click (sent only when set to true) and a tooltip.
        /// Answers come as `input` with `item(id, action)`, `dragBegan(id)`
        /// and `dragEnded(id, succeeded)`.
        case item(id: String, child: ViewNode, hoverFill: WireColor?, cornerRadius: Double?, drag: ItemDrag?, menu: [ActionItem]?, click: Bool?, doubleClick: Bool?, help: String?)
    }

    /// The order of a stack's children across the stack: leading, centre or
    /// trailing for a vertical stack; top, centre or bottom for a horizontal one.
    public enum StackAlignment: String, Codable, Hashable, Sendable {
        case start, center, end
    }

    public enum TextStyle: String, Codable, Hashable, Sendable {
        /// The main line: 15 pt semibold.
        case title
        /// Rows and buttons: 12 pt medium.
        case body
        /// The second line: 11 pt at half opacity.
        case secondary
    }

    public struct Insets: Codable, Hashable, Sendable {
        public var horizontal: Double
        public var vertical: Double
        public init(horizontal: Double = 0, vertical: Double = 0) {
            self.horizontal = horizontal
            self.vertical = vertical
        }
    }

    /// A move after layout, in points; positive is right and down.
    public struct Offset: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double = 0, y: Double = 0) {
            self.x = x
            self.y = y
        }
    }

    /// Where a child sits in a `zstack` or a `frame`.
    public enum Alignment: String, Codable, Hashable, Sendable, CaseIterable {
        case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing
    }

    public enum Axis: String, Codable, Hashable, Sendable {
        case horizontal, vertical
    }

    /// The axes a `frame` fills.
    public enum FrameFill: String, Codable, Hashable, Sendable {
        case width, height, both
    }

    public enum FontWeight: String, Codable, Hashable, Sendable, CaseIterable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    }

    public enum ButtonStyle: String, Codable, Hashable, Sendable {
        /// The version 1 look: a filled capsule.
        case capsule
        /// A capsule in the accent colour, or in `color`.
        case accent
        /// The title alone, no background.
        case plain
    }

    public enum SpinnerSize: String, Codable, Hashable, Sendable {
        case small, mini
    }

    public enum Truncation: String, Codable, Hashable, Sendable {
        case tail, middle
    }

    /// An outline: `dash` is the lengths of dashes and gaps, solid when nil.
    public struct Stroke: Codable, Hashable, Sendable {
        public var color: WireColor
        public var width: Double
        public var dash: [Double]?
        public init(color: WireColor, width: Double, dash: [Double]? = nil) {
            self.color = color
            self.width = width
            self.dash = dash
        }
    }

    /// One run of a `styledText`.
    public struct TextRun: Codable, Hashable, Sendable {
        public var text: String
        public var strikethrough: Bool?
        public init(_ text: String, strikethrough: Bool? = nil) {
            self.text = text
            self.strikethrough = strikethrough
        }
    }

    /// How a `styledText` is drawn. Nil fields take the app's defaults:
    /// 12 pt, regular, white, opaque, one line, truncated at the end.
    public struct TextAttributes: Codable, Hashable, Sendable {
        public var size: Double?
        public var weight: FontWeight?
        public var color: WireColor?
        public var opacity: Double?
        public var lineLimit: Int?
        public var truncation: Truncation?
        public var monospacedDigits: Bool?

        public init(
            size: Double? = nil,
            weight: FontWeight? = nil,
            color: WireColor? = nil,
            opacity: Double? = nil,
            lineLimit: Int? = nil,
            truncation: Truncation? = nil,
            monospacedDigits: Bool? = nil
        ) {
            self.size = size
            self.weight = weight
            self.color = color
            self.opacity = opacity
            self.lineLimit = lineLimit
            self.truncation = truncation
            self.monospacedDigits = monospacedDigits
        }
    }

    /// What an `item` gives when it is dragged out: the pasteboard
    /// entries, and an image asset (sent earlier with `asset`) shown under
    /// the pointer.
    public struct ItemDrag: Codable, Hashable, Sendable {
        public var items: [WireDrop]
        public var image: String?
        public init(_ items: [WireDrop], image: String? = nil) {
            self.items = items
            self.image = image
        }
    }
}

/// A colour: a hex string such as `"#F5A623"`, and an optional opacity
/// from 0 to 1 (opaque when nil).
public struct WireColor: Codable, Hashable, Sendable {
    public var hex: String
    public var opacity: Double?

    public init(_ hex: String, opacity: Double? = nil) {
        self.hex = hex
        self.opacity = opacity
    }
}

/// One thing dropped on the notch, or one entry of an `item`'s drag.
public enum WireDrop: Codable, Hashable, Sendable {
    /// An absolute file path. Files the app wrote for a drop are in the
    /// temporary folder.
    case file(path: String)
    case link(url: String)
    case text(string: String)
}

// MARK: - Building trees

public extension ViewNode {
    static func vstack(spacing: Double? = nil, alignment: StackAlignment? = nil, padding: Insets? = nil, offset: Offset? = nil, _ children: [ViewNode]) -> ViewNode {
        ViewNode(.vstack(children: children, spacing: spacing, alignment: alignment, padding: padding, offset: offset))
    }

    static func hstack(spacing: Double? = nil, alignment: StackAlignment? = nil, padding: Insets? = nil, offset: Offset? = nil, _ children: [ViewNode]) -> ViewNode {
        ViewNode(.hstack(children: children, spacing: spacing, alignment: alignment, padding: padding, offset: offset))
    }

    static func box(
        width: Double? = nil,
        height: Double? = nil,
        cornerRadius: Double,
        fillOpacity: Double,
        color: WireColor? = nil,
        stroke: Stroke? = nil,
        _ child: ViewNode
    ) -> ViewNode {
        ViewNode(.box(child: child, width: width, height: height, cornerRadius: cornerRadius, fillOpacity: fillOpacity, color: color, stroke: stroke))
    }

    static func text(_ text: String, style: TextStyle = .body) -> ViewNode {
        ViewNode(.text(text: text, style: style))
    }

    static func symbol(
        _ name: String,
        size: Double,
        opacity: Double? = nil,
        width: Double? = nil,
        color: WireColor? = nil,
        weight: FontWeight? = nil,
        secondaryColor: WireColor? = nil
    ) -> ViewNode {
        ViewNode(.symbol(name: name, size: size, opacity: opacity, width: width, color: color, weight: weight, secondaryColor: secondaryColor))
    }

    static func image(asset: String, size: Double, cornerRadius: Double = 0) -> ViewNode {
        ViewNode(.image(asset: asset, size: size, cornerRadius: cornerRadius))
    }

    static func progress(_ value: Double, width: Double? = nil, color: WireColor? = nil, drainsOver: Double? = nil, track: WireColor? = nil) -> ViewNode {
        ViewNode(.progress(value: value, width: width, color: color, drainsOver: drainsOver, track: track))
    }

    static func button(
        id: String,
        title: String,
        style: ButtonStyle? = nil,
        symbol: String? = nil,
        enabled: Bool? = nil,
        color: WireColor? = nil,
        restOpacity: Double? = nil,
        labelColor: WireColor? = nil
    ) -> ViewNode {
        ViewNode(.button(id: id, title: title, style: style, symbol: symbol, enabled: enabled, color: color, restOpacity: restOpacity, labelColor: labelColor))
    }

    static func spacer(minLength: Double? = nil) -> ViewNode {
        ViewNode(.spacer(minLength: minLength))
    }

    // Contract version 2.

    static func zstack(alignment: Alignment? = nil, _ children: [ViewNode]) -> ViewNode {
        ViewNode(.zstack(children: children, alignment: alignment))
    }

    static func scroll(_ axis: Axis, _ child: ViewNode) -> ViewNode {
        ViewNode(.scroll(axis: axis, child: child))
    }

    static func styledText(_ runs: [TextRun], _ attributes: TextAttributes = TextAttributes()) -> ViewNode {
        ViewNode(.styledText(runs: runs, attributes: attributes))
    }

    /// One run of styled text.
    static func styledText(
        _ text: String,
        size: Double? = nil,
        weight: FontWeight? = nil,
        color: WireColor? = nil,
        opacity: Double? = nil,
        lineLimit: Int? = nil,
        truncation: Truncation? = nil,
        monospacedDigits: Bool? = nil,
        strikethrough: Bool? = nil
    ) -> ViewNode {
        styledText([TextRun(text, strikethrough: strikethrough)], TextAttributes(
            size: size, weight: weight, color: color, opacity: opacity,
            lineLimit: lineLimit, truncation: truncation, monospacedDigits: monospacedDigits
        ))
    }

    static func capsule(fill: WireColor? = nil, padding: Insets? = nil, height: Double? = nil, _ child: ViewNode) -> ViewNode {
        ViewNode(.capsule(child: child, fill: fill, padding: padding, height: height))
    }

    static func spinner(_ size: SpinnerSize = .small) -> ViewNode {
        ViewNode(.spinner(size: size))
    }

    static func sweep(_ color: WireColor) -> ViewNode {
        ViewNode(.sweep(color: color))
    }

    static func frame(width: Double? = nil, height: Double? = nil, fill: FrameFill? = nil, alignment: Alignment? = nil, _ child: ViewNode) -> ViewNode {
        ViewNode(.frame(child: child, width: width, height: height, fill: fill, alignment: alignment))
    }

    static func item(
        id: String,
        hoverFill: WireColor? = nil,
        cornerRadius: Double? = nil,
        drag: ItemDrag? = nil,
        menu: [ActionItem]? = nil,
        click: Bool? = nil,
        doubleClick: Bool? = nil,
        help: String? = nil,
        _ child: ViewNode
    ) -> ViewNode {
        ViewNode(.item(id: id, child: child, hoverFill: hoverFill, cornerRadius: cornerRadius, drag: drag, menu: menu, click: click, doubleClick: doubleClick, help: help))
    }

    /// A copy of this node with an accessibility label.
    func accessibilityLabel(_ label: String) -> ViewNode {
        var copy = self
        copy.accessibilityLabel = label
        return copy
    }
}

// MARK: - Inspecting trees

public enum ViewNodeError: Error, Equatable {
    case tooManyNodes(count: Int, limit: Int)
}

public extension ViewNode {
    /// This node and every node below it.
    var children: [ViewNode] {
        switch kind {
        case let .vstack(children, _, _, _, _), let .hstack(children, _, _, _, _), let .zstack(children, _): children
        case let .box(child, _, _, _, _, _, _), let .scroll(_, child), let .capsule(child, _, _, _),
             let .frame(child, _, _, _, _), let .item(_, child, _, _, _, _, _, _, _): [child]
        case .text, .symbol, .image, .progress, .button, .spacer, .styledText, .spinner, .sweep: []
        }
    }

    /// The number of nodes in the tree, this one included.
    var nodeCount: Int {
        children.reduce(1) { $0 + $1.nodeCount }
    }

    /// The asset ids the tree refers to, in tree order, without repeats.
    /// An `item`'s drag image comes before the images inside it.
    var assetIDs: [String] {
        var ids: [String] = []
        func add(_ id: String) {
            if !ids.contains(id) { ids.append(id) }
        }
        func walk(_ node: ViewNode) {
            switch node.kind {
            case let .image(asset, _, _): add(asset)
            case let .item(_, _, _, _, drag, _, _, _, _): if let image = drag?.image { add(image) }
            default: break
            }
            node.children.forEach(walk)
        }
        walk(self)
        return ids
    }

    /// Throws when the tree holds more than `Contract.maxNodes` nodes.
    func validate() throws {
        let count = nodeCount
        if count > Contract.maxNodes {
            throw ViewNodeError.tooManyNodes(count: count, limit: Contract.maxNodes)
        }
    }
}

/// A view and the size it asks for. The app clamps the size to its limits.
/// For a wing only the width is used, and 0 is allowed.
public struct ViewSlot: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public var root: ViewNode

    public init(width: Double, height: Double, root: ViewNode) {
        self.width = width
        self.height = height
        self.root = root
    }
}
