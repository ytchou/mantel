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

    /// Contexts of enabled blocks.
    @ObservationIgnored private var contexts: [BlockID: RuntimeContext] = [:]
    @ObservationIgnored private var arbiter = Arbiter()
    @ObservationIgnored private var isPointerInside = false

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
        if enabled { activate(block) }
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
            arbiter.dismiss(id, at: now())
            applyArbiter()
            block.deactivate()
        }
    }

    private func activate(_ block: any NotchBlock) {
        let context = RuntimeContext(block: block.id, runtime: self)
        contexts[block.id] = context
        block.activate(context)
    }

    // MARK: Events

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
