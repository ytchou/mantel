import NotchCore
import SwiftUI

/// The smallest useful block: hovering the notch shows the time.
///
/// Copy this file to start a new block. A block does three things:
/// 1. subscribes to events in `activate`,
/// 2. asks the notch to show a view with `context.present`,
/// 3. removes it with `context.dismiss`.
@MainActor
public final class DemoBlock: NotchBlock {
    public let id: BlockID = "demo"
    public let title = "Clock"

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

    private func hoverChanged(isInside: Bool) {
        guard isInside else {
            context?.dismiss()
            return
        }
        // Ambient: any block with something more important to show wins.
        context?.present(Presentation(
            priority: .ambient,
            expanded: NotchContent(size: CGSize(width: 260, height: 72)) { ClockView() },
            opensAt: .expanded
        ))
    }
}

private struct ClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(timeline.date, format: .dateTime.hour().minute().second())
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
