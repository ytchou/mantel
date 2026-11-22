/// What one event a block listens to tells it, and what macOS must allow
/// before the event's source runs. The install sheet shows one per event.
public struct EventEntry: Sendable, Equatable {
    /// The macOS permission an event's source needs.
    public enum Permission: Sendable, Equatable {
        /// No permission.
        case none
        /// Access to the folder screenshots are saved to.
        case screenshotFolder
    }

    /// The event in the user's words, such as "Screenshots".
    public var name: String
    /// What the event reveals to the block, as one sentence.
    public var reveals: String
    public var permission: Permission
    /// Anything else the user should know, such as reliance on an
    /// undocumented part of macOS. Empty when there is nothing to add.
    public var note: String

    public init(name: String, reveals: String, permission: Permission = .none, note: String = "") {
        self.name = name
        self.reveals = reveals
        self.permission = permission
        self.note = note
    }
}
