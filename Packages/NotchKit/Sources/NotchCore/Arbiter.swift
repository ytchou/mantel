/// Decides which presentation owns the notch, at which level, and when the
/// owner's time runs out. A pure value: time is passed in, nothing waits.
///
/// Time is an offset from an arbitrary origin, so tests can use plain values
/// such as `.seconds(3)`.
@MainActor
struct Arbiter {
    typealias Instant = Duration

    private struct Entry {
        let block: BlockID
        let presentation: Presentation
        /// Higher means presented more recently. Breaks priority ties.
        let order: Int
        /// Time left on screen. `nil` stays until dismissed.
        var remaining: Duration?
    }

    private var entries: [Entry] = []
    private var nextOrder = 0
    private(set) var isPointerInside = false
    /// When the owner's countdown last started. `nil` while it is not running.
    private var runningSince: Instant?

    // MARK: Output

    var state: NotchState {
        guard let index = ownerIndex else { return .idle }
        let entry = entries[index]
        return .showing(owner: entry.block, level: level(of: entry.presentation), presentation: entry.presentation)
    }

    /// When the owner's time runs out, if its countdown is running.
    var nextDeadline: Instant? {
        guard let runningSince, let index = ownerIndex, let remaining = entries[index].remaining else { return nil }
        return runningSince + remaining
    }

    // MARK: Input

    /// Replace the block's presentation. Returns false when the presentation
    /// has no content and was ignored.
    @discardableResult
    mutating func present(_ presentation: Presentation, for block: BlockID, at now: Instant) -> Bool {
        guard presentation.peek != nil || presentation.wing != nil || presentation.expanded != nil else { return false }
        pause(at: now)
        entries.removeAll { $0.block == block }
        entries.append(Entry(block: block, presentation: presentation, order: nextOrder, remaining: presentation.duration))
        nextOrder += 1
        resume(at: now)
        return true
    }

    mutating func dismiss(_ block: BlockID, at now: Instant) {
        pause(at: now)
        entries.removeAll { $0.block == block }
        resume(at: now)
    }

    mutating func setPointerInside(_ inside: Bool, at now: Instant) {
        pause(at: now)
        isPointerInside = inside
        resume(at: now)
    }

    /// Bring the countdown up to `now`, removing presentations whose time ran out.
    mutating func advance(to now: Instant) {
        pause(at: now)
        resume(at: now)
    }

    // MARK: Rules

    private var ownerIndex: Int? {
        entries.indices.max { a, b in
            (entries[a].presentation.priority, entries[a].order) < (entries[b].presentation.priority, entries[b].order)
        }
    }

    private func level(of presentation: Presentation) -> NotchLevel {
        let hasExpanded = presentation.expanded != nil
        if hasExpanded && (presentation.opensAt == .expanded || isPointerInside) { return .expanded }
        return presentation.peek != nil || presentation.wing != nil ? .peek : .expanded
    }

    /// Stop the owner's countdown, keeping the time it has left.
    private mutating func pause(at now: Instant) {
        if let runningSince, let index = ownerIndex, let remaining = entries[index].remaining {
            entries[index].remaining = remaining - (now - runningSince)
        }
        runningSince = nil
    }

    /// Drop owners whose time is used up, then start the new owner's countdown
    /// if it has one and the pointer is outside.
    private mutating func resume(at now: Instant) {
        while let index = ownerIndex, let remaining = entries[index].remaining, remaining <= .zero {
            entries.remove(at: index)
        }
        if !isPointerInside, let index = ownerIndex, entries[index].remaining != nil {
            runningSince = now
        }
    }
}
