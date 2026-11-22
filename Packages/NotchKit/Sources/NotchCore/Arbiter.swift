/// Decides which presentation owns the notch, at which level, and when the
/// owner's time runs out. A pure value: time is passed in, nothing waits.
///
/// Time is an offset from an arbitrary origin, so tests can use plain values
/// such as `.seconds(3)`.
///
/// The owner is the entry with the highest (effective priority, rank). An
/// `interactive` presentation counts as `interactive` only while its block is
/// in an interaction: a drag is in progress, the pointer is on the notch and
/// that block owns it, or less than `interactionWindow` has passed since
/// either ended. Outside that it counts as `standard` when it has a
/// duration, and as `ambient` when it has none: an endless view nobody acts
/// on gives way to any timed view of another block.
@MainActor
struct Arbiter {
    typealias Instant = Duration

    /// How long an interaction still counts after the pointer leaves or a
    /// drag ends. A block may wait up to 16 s for late drops, so this stays above that.
    static let interactionWindow: Duration = .seconds(20)

    private struct Entry {
        let block: BlockID
        let presentation: Presentation
        /// Higher means presented more recently. Decides only between blocks
        /// that are both missing from the rank.
        let order: Int
        /// Time left on screen. `nil` stays until dismissed.
        var remaining: Duration?
    }

    private var entries: [Entry] = []
    private var nextOrder = 0
    private(set) var isPointerInside = false
    /// When the owner's countdown last started. `nil` while it is not running.
    private var runningSince: Instant?

    /// Position of each block in the rank; 0 is the highest.
    private var rank: [BlockID: Int] = [:]
    /// The latest instant passed in. The guard reads it.
    private var now: Instant = .zero
    private var isDragActive = false
    /// When the window after the last drag ends, for every block.
    private var dragWindowEnd: Instant?
    /// The block that owns the notch while the pointer is on it.
    private var pointerOwner: BlockID?
    /// When the window after the pointer left ends, per block.
    private var pointerWindowEnd: [BlockID: Instant] = [:]

    // MARK: Output

    var state: NotchState {
        guard let index = ownerIndex else { return .idle }
        let entry = entries[index]
        return .showing(owner: entry.block, level: level(of: entry.presentation), presentation: entry.presentation)
    }

    /// The next instant at which the decision can change by time alone: the
    /// owner's time runs out, or an interaction window of an `interactive`
    /// presentation ends.
    var nextDeadline: Instant? {
        var deadlines: [Instant] = []
        if let runningSince, let index = ownerIndex, let remaining = entries[index].remaining {
            deadlines.append(runningSince + remaining)
        }
        for entry in entries where entry.presentation.priority == .interactive {
            if let end = windowEnd(of: entry.block) { deadlines.append(end) }
        }
        return deadlines.min()
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
        if !inside, let pointerOwner {
            pointerWindowEnd[pointerOwner] = now + Self.interactionWindow
            self.pointerOwner = nil
        }
        resume(at: now)
    }

    /// A drag started (`true`) or ended (`false`) somewhere on screen.
    mutating func setDragActive(_ active: Bool, at now: Instant) {
        pause(at: now)
        if isDragActive && !active { dragWindowEnd = now + Self.interactionWindow }
        isDragActive = active
        resume(at: now)
    }

    /// The order that decides between equal priorities, highest first. Blocks
    /// not in the list come after every block in it.
    mutating func setRank(_ blocks: [BlockID], at now: Instant) {
        pause(at: now)
        rank = Dictionary(blocks.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        resume(at: now)
    }

    /// Bring the countdown up to `now`, removing presentations whose time ran out.
    mutating func advance(to now: Instant) {
        pause(at: now)
        resume(at: now)
    }

    // MARK: Rules

    private var ownerIndex: Int? {
        entries.indices.max { a, b in key(of: entries[a]) < key(of: entries[b]) }
    }

    /// (effective priority, rank, recency); a higher key wins.
    private func key(of entry: Entry) -> (Int, Int, Int) {
        var priority = entry.presentation.priority
        if priority == .interactive, !isInteracting(entry.block) {
            priority = entry.presentation.duration == nil ? .ambient : .standard
        }
        let rankKey = rank[entry.block].map { -$0 } ?? Int.min
        return (priority.rawValue, rankKey, entry.order)
    }

    private func isInteracting(_ block: BlockID) -> Bool {
        isDragActive || pointerOwner == block || windowEnd(of: block) != nil
    }

    /// The end of the block's interaction window, if it is still open.
    private func windowEnd(of block: BlockID) -> Instant? {
        [dragWindowEnd, pointerWindowEnd[block]].compactMap { $0 }.filter { $0 > now }.max()
    }

    private func level(of presentation: Presentation) -> NotchLevel {
        let hasExpanded = presentation.expanded != nil
        if hasExpanded && (presentation.opensAt == .expanded || isPointerInside) { return .expanded }
        return presentation.peek != nil || presentation.wing != nil ? .peek : .expanded
    }

    /// Stop the owner's countdown, keeping the time it has left. The owner is
    /// decided at the previous instant, then the clock moves to `now`.
    private mutating func pause(at now: Instant) {
        if let runningSince, let index = ownerIndex, let remaining = entries[index].remaining {
            entries[index].remaining = remaining - (now - runningSince)
        }
        runningSince = nil
        self.now = max(self.now, now)
    }

    /// Drop owners whose time is used up, close ended windows, note which
    /// block the pointer is on, then start the new owner's countdown if it has
    /// one and the pointer is outside.
    private mutating func resume(at now: Instant) {
        while let index = ownerIndex, let remaining = entries[index].remaining, remaining <= .zero {
            entries.remove(at: index)
        }
        if let end = dragWindowEnd, end <= self.now { dragWindowEnd = nil }
        pointerWindowEnd = pointerWindowEnd.filter { $0.value > self.now }
        if isPointerInside {
            let owner = ownerIndex.map { entries[$0].block }
            if owner != pointerOwner {
                if let previous = pointerOwner { pointerWindowEnd[previous] = self.now + Self.interactionWindow }
                pointerOwner = owner
            }
        }
        if !isPointerInside, let index = ownerIndex, entries[index].remaining != nil {
            runningSince = now
        }
    }
}
