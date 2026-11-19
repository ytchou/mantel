import NotchCore
import Observation
import SwiftUI

/// The smallest block that uses the whole contract: hovering the notch opens
/// a panel, a click is counted, and a drop is named back.
///
/// It is for trying the shell and as a template. The app registers it only
/// when launched with `-demoBlock YES`.
///
/// Copy this file to start a new block. A block does four things:
/// 1. subscribes to events in `activate`,
/// 2. asks the notch to show a view with `context.present`,
/// 3. reacts to clicks and drops in `handle`,
/// 4. removes its view with `context.dismiss`.
@MainActor
public final class DemoBlock: NotchBlock {
    public let id: BlockID = "demo"
    public let title = "Demo"
    public let info = BlockInfo(
        summary: "Counts clicks and names what you drop. For trying the notch, and a template for new blocks.",
        symbol: "hammer",
        trigger: "Always shown"
    )

    /// What the view shows. The view observes it, so a change needs no new
    /// `present` call.
    @MainActor
    @Observable
    final class Model {
        var clicks = 0
        var lastDrop: String?
    }

    let model = Model()
    private var context: (any BlockContext)?

    public init() {}

    public func activate(_ context: any BlockContext) {
        self.context = context
        context.subscribe(to: PointerHoverChanged.self) { [weak self] event in
            self?.hoverChanged(isInside: event.isInside)
        }
    }

    public func deactivate() {
        context = nil
    }

    public func handle(_ input: NotchInput) {
        switch input {
        case .click:
            model.clicks += 1
        case let .drop(items):
            model.lastDrop = Self.describe(items)
        }
    }

    private func hoverChanged(isInside: Bool) {
        guard isInside else {
            context?.dismiss()
            model.lastDrop = nil
            return
        }
        let model = self.model
        // Ambient: any block with something more important to show wins.
        context?.present(Presentation(
            priority: .ambient,
            expanded: NotchContent(size: CGSize(width: 280, height: 84)) { DemoView(model: model) },
            opensAt: .expanded,
            accepts: [.file, .link, .text]
        ))
    }

    static func describe(_ items: [DroppedItem]) -> String {
        guard let first = items.first else { return "" }
        let name = switch first {
        case let .file(url): url.lastPathComponent
        case let .link(url): url.host() ?? url.absoluteString
        case let .text(text): "\u{201C}\(text.prefix(24))\u{201D}"
        }
        return items.count == 1 ? name : "\(name) + \(items.count - 1) more"
    }
}

private struct DemoView: View {
    let model: DemoBlock.Model

    var body: some View {
        VStack(spacing: 4) {
            Text("Clicks: \(model.clicks)")
                .font(NotchStyle.title)
                .monospacedDigit()
            Text(model.lastDrop.map { "Dropped: \($0)" } ?? "Drop something here")
                .font(NotchStyle.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(NotchStyle.secondaryOpacity)
        }
        .padding(.horizontal, NotchStyle.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
