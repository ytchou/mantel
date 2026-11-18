import SwiftUI

/// Stable identifier of a block, such as `"shelf"`. Used as a settings key.
public struct BlockID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// Input the shell forwards to the block that owns the notch.
///
/// Controls inside a block's own view (buttons, lists) handle their own
/// clicks. This is only for input on the notch as a whole.
public enum NotchInput: Sendable {
    /// A click on the notch shape outside any control.
    case click
    /// Items dropped on the notch. Only kinds in `Presentation.accepts` arrive.
    case drop([DroppedItem])
}

/// A command a block offers outside its own view, for menus and shortcuts.
@MainActor
public struct BlockAction: Identifiable {
    public let id: String
    public let title: String
    public let isEnabled: Bool
    public let perform: @MainActor () -> Void

    public init(id: String, title: String, isEnabled: Bool = true, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// What the runtime gives a block. It is the block's only way to reach the notch.
@MainActor
public protocol BlockContext: AnyObject {
    /// Receive every event of one type. Subscriptions end when the block is
    /// deactivated; there is nothing to cancel.
    func subscribe<E: NotchEvent>(to type: E.Type, _ handler: @escaping @MainActor (E) -> Void)

    /// Ask the notch to show something. Replaces this block's earlier
    /// presentation. The arbiter decides whether it is shown now or waits.
    func present(_ presentation: Presentation)

    /// Remove this block's presentation. Does nothing when there is none.
    func dismiss()

    /// True while this block's presentation is the one on screen.
    var ownsNotch: Bool { get }
}

/// A capability of the notch. A block reacts to events and asks the notch to
/// show things. It never touches the notch window or another block.
@MainActor
public protocol NotchBlock: AnyObject {
    var id: BlockID { get }
    /// Name shown in settings.
    var title: String { get }

    /// The block was turned on. Subscribe to events here and keep `context`.
    func activate(_ context: any BlockContext)

    /// The block was turned off. Stop work in progress. The runtime has already
    /// removed the block's subscriptions and presentation.
    func deactivate()

    /// Input on the notch while this block owns it.
    func handle(_ input: NotchInput)

    /// Commands for menus and shortcuts.
    var actions: [BlockAction] { get }

    /// The block's pane in the settings window, if it has one.
    var settingsPane: AnyView? { get }
}

public extension NotchBlock {
    func deactivate() {}
    func handle(_ input: NotchInput) {}
    var actions: [BlockAction] { [] }
    var settingsPane: AnyView? { nil }
}
