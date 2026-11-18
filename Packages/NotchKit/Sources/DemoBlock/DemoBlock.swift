import NotchCore
import Observation
import SwiftUI

/// The smallest block that uses the whole contract: hovering the notch shows
/// the time, a click shows or hides the seconds, and a drop is named back.
///
/// Copy this file to start a new block. A block does four things:
/// 1. subscribes to events in `activate`,
/// 2. asks the notch to show a view with `context.present`,
/// 3. reacts to clicks and drops in `handle`,
/// 4. removes its view with `context.dismiss`.
@MainActor
public final class DemoBlock: NotchBlock {
    public let id: BlockID = "demo"
    public let title = "Clock"

    /// What the view shows. The view observes it, so a change needs no new
    /// `present` call.
    @MainActor
    @Observable
    final class Model {
        var showsSeconds = true
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
            model.showsSeconds.toggle()
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
            expanded: NotchContent(size: CGSize(width: 280, height: 84)) { ClockView(model: model) },
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

private struct ClockView: View {
    let model: DemoBlock.Model

    var body: some View {
        VStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(timeline.date, format: model.showsSeconds
                    ? .dateTime.hour().minute().second()
                    : .dateTime.hour().minute())
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            if let lastDrop = model.lastDrop {
                Text("Dropped: \(lastDrop)")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(0.7)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
