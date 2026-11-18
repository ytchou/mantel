import Observation

/// Holds the blocks, routes events to them, and decides what the notch shows.
///
/// Three callers use it:
/// - the app registers blocks,
/// - event sources publish events,
/// - the shell reads `state` to draw, and reports hover and input.
@MainActor
@Observable
public final class NotchRuntime {
    /// What the notch shows now. Observable; the shell redraws when it changes.
    public private(set) var state: NotchState = .idle

    /// Registered blocks, in registration order.
    public private(set) var blocks: [any NotchBlock] = []

    public init() {}

    // MARK: Blocks

    /// Add a block. An enabled block is activated at once.
    public func register(_ block: any NotchBlock, enabled: Bool = true) {
        blocks.append(block)
    }

    public func isEnabled(_ id: BlockID) -> Bool { false }

    /// Turn a block on or off. Turning it off removes its subscriptions and
    /// its presentation, then calls `deactivate()`.
    public func setEnabled(_ id: BlockID, _ enabled: Bool) {}

    // MARK: Events

    /// Deliver an event to every enabled block subscribed to its type.
    public func publish<E: NotchEvent>(_ event: E) {}

    // MARK: Shell input

    /// The pointer entered or left the notch shape. Updates the level of the
    /// current presentation and publishes `PointerHoverChanged`.
    public func pointerHoverChanged(isInside: Bool) {}

    /// Forward input to the block that owns the notch. Dropped when idle.
    public func send(_ input: NotchInput) {}
}
