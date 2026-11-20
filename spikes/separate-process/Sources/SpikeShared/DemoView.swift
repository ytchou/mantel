import SwiftUI

/// Option 1 ("described view"): a view as plain data, like WidgetKit. The
/// block builds it; whoever draws it renders it with `NodeView`.
public indirect enum Node: Codable, Hashable, Sendable {
    case vstack([Node])
    case hstack([Node])
    case text(String, size: Double, weight: String, opacity: Double)
    case symbol(String, size: Double)
    case button(id: String, label: String)
    case spacer
}

/// The state of the test block: the same idea as DemoBlock (hover, click
/// count, name of what is dragged over).
public struct DemoState: Sendable {
    public var inside = false
    public var clicks = 0
    public var dragName: String?

    public init() {}

    public mutating func apply(_ input: Input) {
        switch input {
        case let .hover(v): inside = v; if !v { dragName = nil }
        case .click: clicks += 1
        case let .dragOver(name): dragName = name
        case let .drop(names): dragName = "dropped \(names.first ?? "")"
        }
    }

    public func nodes() -> [Node] {
        let second = dragName.map { "Drag over: \($0)" } ?? (inside ? "Pointer inside" : "Drop something here")
        return [.hstack([
            .symbol(inside ? "hand.point.up.left.fill" : "hammer", size: 22),
            .vstack([
                .text("Clicks: \(clicks)", size: 15, weight: "semibold", opacity: 1),
                .text(second, size: 11, weight: "regular", opacity: 0.7),
            ]),
            .spacer,
            .button(id: "reset", label: "Reset"),
        ])]
    }
}

@MainActor
public final class ViewModel: ObservableObject {
    @Published public var nodes: [Node]
    /// Input sequence number this content answers. Read by the body so every
    /// update re-evaluates it, and handed to `Probe`.
    @Published public var version: Int = 0
    public var onButton: ((String) -> Void)?
    public init(nodes: [Node] = DemoState().nodes()) { self.nodes = nodes }
}

public struct NodeRootView: View {
    @ObservedObject var model: ViewModel
    public init(model: ViewModel) { self.model = model }

    public var body: some View {
        let _ = Probe.bodyEvaluated(version: model.version)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.nodes.enumerated()), id: \.offset) { _, n in NodeView(node: n, onButton: model.onButton) }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }
}

struct NodeView: View {
    let node: Node
    let onButton: ((String) -> Void)?

    var body: some View {
        switch node {
        case let .vstack(children):
            VStack(alignment: .leading, spacing: 3) { ForEach(Array(children.enumerated()), id: \.offset) { NodeView(node: $1, onButton: onButton) } }
        case let .hstack(children):
            HStack(spacing: 10) { ForEach(Array(children.enumerated()), id: \.offset) { NodeView(node: $1, onButton: onButton) } }
        case let .text(s, size, weight, opacity):
            Text(s).font(.system(size: size, weight: weight == "semibold" ? .semibold : .regular))
                .monospacedDigit().lineLimit(1).opacity(opacity)
        case let .symbol(name, size):
            Image(systemName: name).font(.system(size: size))
        case let .button(id, label):
            Button(label) { onButton?(id) }.buttonStyle(.bordered)
        case .spacer:
            Spacer(minLength: 0)
        }
    }
}
