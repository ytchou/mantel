import SwiftUI

/// How much of the notch a presentation uses.
public enum NotchLevel: Sendable, Hashable {
    /// A small strip that hangs just under the notch.
    case peek
    /// The large panel.
    case expanded
}

/// Who wins when several blocks want the notch. Higher wins.
public enum PresentationPriority: Int, Sendable, Comparable, CaseIterable {
    /// Standing information, such as "3 items on the shelf".
    case ambient = 0
    /// A result the user should see, such as a finished rename.
    case standard = 1
    /// The user is acting on the notch right now, such as during a drag.
    case interactive = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Size limits the shell enforces. A larger request is clamped, not rejected.
///
/// The peek hangs below the menu bar, so it never covers menu bar items. The
/// expanded panel is wider than the notch and does cover the items next to it
/// while it is open; that is accepted because it is short-lived.
public enum NotchLimits {
    public static let maxPeekSize = CGSize(width: 360, height: 44)
    public static let maxExpandedSize = CGSize(width: 520, height: 280)
    /// Widest a wing may be. Its height is always the notch's height.
    public static let maxWingWidth: CGFloat = 80

    public static func clamp(_ size: CGSize, for level: NotchLevel) -> CGSize {
        let limit = level == .peek ? maxPeekSize : maxExpandedSize
        return CGSize(width: min(max(size.width, 0), limit.width),
                      height: min(max(size.height, 0), limit.height))
    }
}

/// A view a block gives to the notch, with the size it wants.
///
/// The view is the block's own. Keep its state in an observable model owned by
/// the block: the view then updates in place, with no new request.
@MainActor
public struct NotchContent {
    /// Wanted size of the content area. Clamped to `NotchLimits`.
    public let size: CGSize
    public let makeView: @MainActor () -> AnyView

    public init<V: View>(size: CGSize, @ViewBuilder _ view: @escaping @MainActor () -> V) {
        self.size = size
        self.makeView = { AnyView(view()) }
    }
}

/// What a block asks the notch to show.
///
/// A block has at most one presentation at a time. Presenting again replaces
/// the block's earlier one.
@MainActor
public struct Presentation: Identifiable {
    /// New for every value. The shell rebuilds its views when this changes.
    public let id = UUID()
    public var priority: PresentationPriority
    /// Shown at `.peek`. At least one of `peek` and `expanded` must be set.
    public var peek: NotchContent?
    /// A small view beside the notch, inside the menu bar. When set, it is
    /// shown at the peek level instead of `peek`, so the notch takes no room
    /// below the menu bar. Only its width is used, up to
    /// `NotchLimits.maxWingWidth`. Keep it to an icon and a few characters.
    public var wing: NotchContent?
    /// Shown at `.expanded`.
    public var expanded: NotchContent?
    /// The level the presentation starts at and returns to when the pointer
    /// leaves. With `.peek`, hovering expands it when `expanded` is set.
    public var opensAt: NotchLevel
    /// Time on screen before it is removed. `nil` stays until dismissed.
    /// The time runs only while this presentation owns the notch and the
    /// pointer is outside it.
    public var duration: Duration?
    /// Kinds of dropped content this presentation takes. Empty takes none.
    public var accepts: Set<DropKind>

    public init(
        priority: PresentationPriority = .standard,
        peek: NotchContent? = nil,
        wing: NotchContent? = nil,
        expanded: NotchContent? = nil,
        opensAt: NotchLevel = .peek,
        duration: Duration? = nil,
        accepts: Set<DropKind> = []
    ) {
        self.priority = priority
        self.peek = peek
        self.wing = wing
        self.expanded = expanded
        self.opensAt = opensAt
        self.duration = duration
        self.accepts = accepts
    }
}

/// What the notch shows right now. The arbiter owns it; the shell draws it.
@MainActor
public enum NotchState {
    case idle
    case showing(owner: BlockID, level: NotchLevel, presentation: Presentation)

    public var owner: BlockID? {
        if case let .showing(owner, _, _) = self { owner } else { nil }
    }

    public var level: NotchLevel? {
        if case let .showing(_, level, _) = self { level } else { nil }
    }

    public var presentation: Presentation? {
        if case let .showing(_, _, presentation) = self { presentation } else { nil }
    }
}
