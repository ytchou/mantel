import Foundation

/// One element of a block's view, sent as data. The app draws it.
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
        /// Children top to bottom.
        case vstack(children: [ViewNode], spacing: Double?, alignment: StackAlignment?, padding: Insets?)
        /// Children left to right.
        case hstack(children: [ViewNode], spacing: Double?, alignment: StackAlignment?, padding: Insets?)
        /// A rounded rectangle filled with white at `fillOpacity`, with one
        /// child centred on it. Used for an artwork placeholder.
        case box(child: ViewNode, width: Double, height: Double, cornerRadius: Double, fillOpacity: Double)
        /// One line of text, truncated at the end.
        case text(text: String, style: TextStyle)
        /// An SF Symbol. `width` fixes the frame width so a changing symbol
        /// does not move its neighbours.
        case symbol(name: String, size: Double, opacity: Double?, width: Double?)
        /// An image sent earlier with `asset`, square, filled and clipped.
        case image(asset: String, size: Double, cornerRadius: Double)
        /// A thin capsule bar, filled from the left by `value` (0 to 1).
        case progress(value: Double, width: Double)
        /// A capsule button. A click sends `input` with `button(id)`.
        case button(id: String, title: String)
        /// Flexible space.
        case spacer(minLength: Double?)
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
}

// MARK: - Building trees

public extension ViewNode {
    static func vstack(spacing: Double? = nil, alignment: StackAlignment? = nil, padding: Insets? = nil, _ children: [ViewNode]) -> ViewNode {
        ViewNode(.vstack(children: children, spacing: spacing, alignment: alignment, padding: padding))
    }

    static func hstack(spacing: Double? = nil, alignment: StackAlignment? = nil, padding: Insets? = nil, _ children: [ViewNode]) -> ViewNode {
        ViewNode(.hstack(children: children, spacing: spacing, alignment: alignment, padding: padding))
    }

    static func box(width: Double, height: Double, cornerRadius: Double, fillOpacity: Double, _ child: ViewNode) -> ViewNode {
        ViewNode(.box(child: child, width: width, height: height, cornerRadius: cornerRadius, fillOpacity: fillOpacity))
    }

    static func text(_ text: String, style: TextStyle = .body) -> ViewNode {
        ViewNode(.text(text: text, style: style))
    }

    static func symbol(_ name: String, size: Double, opacity: Double? = nil, width: Double? = nil) -> ViewNode {
        ViewNode(.symbol(name: name, size: size, opacity: opacity, width: width))
    }

    static func image(asset: String, size: Double, cornerRadius: Double = 0) -> ViewNode {
        ViewNode(.image(asset: asset, size: size, cornerRadius: cornerRadius))
    }

    static func progress(_ value: Double, width: Double) -> ViewNode {
        ViewNode(.progress(value: value, width: width))
    }

    static func button(id: String, title: String) -> ViewNode {
        ViewNode(.button(id: id, title: title))
    }

    static func spacer(minLength: Double? = nil) -> ViewNode {
        ViewNode(.spacer(minLength: minLength))
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
        case let .vstack(children, _, _, _), let .hstack(children, _, _, _): children
        case let .box(child, _, _, _, _): [child]
        case .text, .symbol, .image, .progress, .button, .spacer: []
        }
    }

    /// The number of nodes in the tree, this one included.
    var nodeCount: Int {
        children.reduce(1) { $0 + $1.nodeCount }
    }

    /// The asset ids the tree refers to, in tree order, without repeats.
    var assetIDs: [String] {
        var ids: [String] = []
        func walk(_ node: ViewNode) {
            if case let .image(asset, _, _) = node.kind, !ids.contains(asset) { ids.append(asset) }
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
