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

    /// Registered blocks, highest rank first. Between two presentations of
    /// equal priority, the block earlier in this list gets the notch. A new
    /// block goes to the end; `move(_:to:)` changes the order.
    public private(set) var blocks: [any NotchBlock] = []

    /// Called once each time the set of event types with at least one
    /// subscriber among enabled blocks changes. Read `hasSubscribers(for:)`
    /// to see the new set.
    @ObservationIgnored public var onDemandChanged: (@MainActor () -> Void)?

    /// Contexts of enabled blocks.
    @ObservationIgnored private var contexts: [BlockID: RuntimeContext] = [:]
    @ObservationIgnored private var arbiter = Arbiter()
    @ObservationIgnored private var isPointerInside = false
    /// Event types with at least one subscriber, as last reported.
    @ObservationIgnored private var demand: Set<ObjectIdentifier> = []

    /// Time since the runtime was created, on the injected clock.
    private let now: @Sendable () -> Duration
    /// Sleep until an instant returned by `now`.
    private let sleepUntil: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var timerDeadline: Duration?

    public convenience init() {
        self.init(clock: ContinuousClock())
    }

    /// Use `clock` for presentation durations. Tests pass a manual clock.
    public init<C: Clock>(clock: C) where C.Duration == Duration {
        let start = clock.now
        now = { start.duration(to: clock.now) }
        sleepUntil = { try await clock.sleep(until: start.advanced(by: $0), tolerance: nil) }
    }

    // MARK: Blocks

    /// Add a block. An enabled block is activated at once. A second block with
    /// an id already registered is ignored.
    public func register(_ block: any NotchBlock, enabled: Bool = true) {
        guard !blocks.contains(where: { $0.id == block.id }) else { return }
        blocks.append(block)
        rankChanged()
        if enabled { activate(block) }
    }

    /// Move a block to `index` in `blocks`, which is its rank. An index past
    /// the end moves it last. An unknown id does nothing.
    public func move(_ id: BlockID, to index: Int) {
        guard let from = blocks.firstIndex(where: { $0.id == id }) else { return }
        let block = blocks.remove(at: from)
        blocks.insert(block, at: min(max(index, 0), blocks.count))
        rankChanged()
    }

    /// Put the blocks in `ids` first, in that order, then every other block
    /// in its current relative order. Unknown ids are ignored. Re-ranks once.
    public func setOrder(_ ids: [BlockID]) {
        var rest = blocks
        var ordered: [any NotchBlock] = []
        for id in ids {
            guard let index = rest.firstIndex(where: { $0.id == id }) else { continue }
            ordered.append(rest.remove(at: index))
        }
        let next = ordered + rest
        guard next.map(\.id) != blocks.map(\.id) else { return }
        blocks = next
        rankChanged()
    }

    private func rankChanged() {
        arbiter.setRank(blocks.map(\.id), at: now())
        applyArbiter()
    }

    public func isEnabled(_ id: BlockID) -> Bool { contexts[id] != nil }

    /// Turn a block on or off. Turning it off removes its subscriptions and
    /// its presentation, then calls `deactivate()`.
    public func setEnabled(_ id: BlockID, _ enabled: Bool) {
        guard enabled != isEnabled(id), let block = blocks.first(where: { $0.id == id }) else { return }
        if enabled {
            activate(block)
        } else {
            contexts.removeValue(forKey: id)?.close()
            subscriptionsChanged()
            arbiter.dismiss(id, at: now())
            applyArbiter()
            block.deactivate()
        }
    }

    /// Remove a block, the reverse of `register`. An enabled block is turned
    /// off first, as by `setEnabled(_:false)`. An unknown id does nothing.
    public func unregister(_ id: BlockID) {
        guard blocks.contains(where: { $0.id == id }) else { return }
        setEnabled(id, false)
        blocks.removeAll { $0.id == id }
        rankChanged()
    }

    private func activate(_ block: any NotchBlock) {
        let context = RuntimeContext(block: block.id, runtime: self)
        contexts[block.id] = context
        block.activate(context)
    }

    // MARK: Events

    /// True when an enabled block subscribes to events of `type`.
    public func hasSubscribers(for type: any NotchEvent.Type) -> Bool {
        demand.contains(ObjectIdentifier(type))
    }

    /// A block subscribed to `type`. Adds it to the demand; reports a change
    /// only when no enabled block listened to it before.
    fileprivate func subscribed(to type: ObjectIdentifier) {
        guard demand.insert(type).inserted else { return }
        onDemandChanged?()
    }

    /// Recompute which event types have subscribers; report a change once.
    fileprivate func subscriptionsChanged() {
        var next: Set<ObjectIdentifier> = []
        for context in contexts.values {
            for (type, handlers) in context.handlers where !handlers.isEmpty { next.insert(type) }
        }
        guard next != demand else { return }
        demand = next
        onDemandChanged?()
    }

    /// Deliver an event to every enabled block subscribed to its type.
    public func publish<E: NotchEvent>(_ event: E) {
        let type = ObjectIdentifier(E.self)
        // Iterate copies, so handlers may register, subscribe or present freely.
        for block in blocks {
            guard let context = contexts[block.id] else { continue }
            for handler in context.handlers[type] ?? [] {
                guard context.isActive else { break }
                handler(event)
            }
        }
    }

    // MARK: Shell input

    /// The pointer entered or left the notch shape. Updates the level of the
    /// current presentation and publishes `PointerHoverChanged`.
    public func pointerHoverChanged(isInside: Bool) {
        guard isInside != isPointerInside else { return }
        isPointerInside = isInside
        arbiter.setPointerInside(isInside, at: now())
        applyArbiter()
        publish(PointerHoverChanged(isInside: isInside))
    }

    /// A system drag started or ended. Starts or ends the arbiter's drag
    /// interaction. The drag source calls it before it publishes
    /// `DragSessionStarted` or `DragSessionEnded`, so the state is set before
    /// any block hears the event.
    public func dragSessionChanged(active: Bool) {
        arbiter.setDragActive(active, at: now())
        applyArbiter()
    }

    /// Forward input to the block that owns the notch. Dropped when idle.
    public func send(_ input: NotchInput) {
        guard let owner = state.owner, let presentation = state.presentation,
              let block = blocks.first(where: { $0.id == owner }) else { return }
        switch input {
        case .click:
            block.handle(input)
        case let .drop(items):
            let accepted = items.filter { presentation.accepts.contains($0.kind) }
            if !accepted.isEmpty { block.handle(.drop(accepted)) }
        }
    }

    // MARK: Context calls

    fileprivate func present(_ presentation: Presentation, for block: BlockID) {
        guard arbiter.present(presentation, for: block, at: now()) else { return }
        applyArbiter()
    }

    fileprivate func dismiss(_ block: BlockID) {
        arbiter.dismiss(block, at: now())
        applyArbiter()
    }

    // MARK: Arbiter

    /// Copy the arbiter's decision into `state`, only when something visible
    /// changed, and schedule the next timeout.
    private func applyArbiter() {
        let next = arbiter.state
        if next.owner != state.owner || next.level != state.level || next.presentation?.id != state.presentation?.id {
            state = next
        }
        scheduleTimer()
    }

    private func scheduleTimer() {
        let deadline = arbiter.nextDeadline
        guard deadline != timerDeadline else { return }
        timer?.cancel()
        timer = nil
        timerDeadline = deadline
        guard let deadline else { return }
        // The task holds the runtime only weakly; a sleeping task outlives a
        // dropped runtime until its deadline, which is harmless.
        timer = Task { @MainActor [weak self, sleepUntil] in
            do { try await sleepUntil(deadline) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.timerDeadline = nil
            self.arbiter.advance(to: self.now())
            self.applyArbiter()
        }
    }
}

/// The `BlockContext` the runtime gives one activated block. It goes inert
/// when the block is deactivated; re-enabling creates a new one.
@MainActor
private final class RuntimeContext: BlockContext {
    let block: BlockID
    weak var runtime: NotchRuntime?
    private(set) var isActive = true
    private(set) var handlers: [ObjectIdentifier: [@MainActor (any NotchEvent) -> Void]] = [:]

    init(block: BlockID, runtime: NotchRuntime) {
        self.block = block
        self.runtime = runtime
    }

    func close() {
        isActive = false
        handlers = [:]
    }

    func subscribe<E: NotchEvent>(to type: E.Type, _ handler: @escaping @MainActor (E) -> Void) {
        guard isActive else { return }
        handlers[ObjectIdentifier(type), default: []].append { event in
            if let event = event as? E { handler(event) }
        }
        runtime?.subscribed(to: ObjectIdentifier(type))
    }

    func unsubscribeAll() {
        guard isActive, !handlers.isEmpty else { return }
        handlers = [:]
        runtime?.subscriptionsChanged()
    }

    func present(_ presentation: Presentation) {
        guard isActive else { return }
        runtime?.present(presentation, for: block)
    }

    func dismiss() {
        guard isActive else { return }
        runtime?.dismiss(block)
    }

    var ownsNotch: Bool { isActive && runtime?.state.owner == block }
}
