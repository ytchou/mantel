import Foundation

/// One event as a block receives it.
public struct BlockEvent: Sendable, Hashable {
    public let payload: EventPayload
    /// True when the app resends the latest event to a block that just
    /// started. Update state; do not present.
    public let replay: Bool

    public init(payload: EventPayload, replay: Bool) {
        self.payload = payload
        self.replay = replay
    }

    public var name: WireEvent { payload.name }

    public var pointerHover: PointerHover? {
        if case let .pointerHover(value) = payload { value } else { nil }
    }

    public var outputVolume: OutputVolume? {
        if case let .outputVolume(value) = payload { value } else { nil }
    }

    public var nowPlaying: NowPlaying? {
        if case let .nowPlaying(value) = payload { value } else { nil }
    }

    public var screenshot: Screenshot? {
        if case let .screenshotCaptured(value) = payload { value } else { nil }
    }

    public var dragStarted: DragStarted? {
        if case let .dragStarted(value) = payload { value } else { nil }
    }
}

/// What a block uses to talk to the app. Given to `Block.start`.
@MainActor
public final class Context {
    /// Every declared setting's current value, keyed without the block id.
    public private(set) var settings: [String: SettingValue] = [:]
    /// A folder the block may write to. Removed with the block.
    public private(set) var dataFolder = URL(fileURLWithPath: NSTemporaryDirectory())
    /// Whether the block's presentation is the one on screen. Becomes false
    /// when it is dismissed, replaced or its time runs out.
    public private(set) var ownsNotch = false

    private let transport: any Transport
    private(set) var generation: Int
    private var assets = Assets()
    private var started = false
    private var eventHandlers: [WireEvent: [(BlockEvent) -> Void]] = [:]
    private var actionHandler: ((String) -> Void)?
    private var inputHandler: ((WireInput) -> Void)?
    private var ownerHandler: ((Bool) -> Void)?
    private var settingHandler: ((String, SettingValue) -> Void)?

    init(transport: any Transport, generation: Int) {
        self.transport = transport
        self.generation = generation
    }

    // MARK: Events and input

    /// Calls `handler` for each event of this kind. The app sends only the
    /// events the manifest lists.
    public func on(_ event: WireEvent, _ handler: @escaping (BlockEvent) -> Void) {
        eventHandlers[event, default: []].append(handler)
    }

    /// Calls `handler` with the id of a menu action the user chose.
    public func onAction(_ handler: @escaping (String) -> Void) { actionHandler = handler }

    /// Calls `handler` when the user clicks the view or one of its buttons.
    public func onInput(_ handler: @escaping (WireInput) -> Void) { inputHandler = handler }

    /// Calls `handler` when `ownsNotch` changes.
    public func onOwnerChanged(_ handler: @escaping (Bool) -> Void) { ownerHandler = handler }

    /// Calls `handler` after the user changed a setting; `settings` already
    /// holds the new value.
    public func onSettingChanged(_ handler: @escaping (String, SettingValue) -> Void) { settingHandler = handler }

    /// A toggle's value, or nil when the app sent none.
    public func bool(_ key: String) -> Bool? { settings[key]?.bool }

    /// A choice's value, or nil when the app sent none.
    public func string(_ key: String) -> String? { settings[key]?.string }

    // MARK: The view

    /// An `image` node for these bytes (PNG or JPEG). The bytes are sent to
    /// the app the first time a tree that shows them is presented.
    public func image(_ bytes: Data, size: Double, cornerRadius: Double = 0) -> ViewNode {
        .image(asset: assets.register(bytes), size: size, cornerRadius: cornerRadius)
    }

    /// Asks for the notch. `seconds` dismisses the presentation after that
    /// long; nil keeps it until `dismiss`. With `dismissIfNotShown`, the app
    /// withdraws it at once if another block holds the notch.
    public func present(
        peek: ViewSlot? = nil,
        wing: ViewSlot? = nil,
        expanded: ViewSlot? = nil,
        priority: Priority = .standard,
        opensAt: Level = .peek,
        for seconds: Double? = nil,
        dismissIfNotShown: Bool = false
    ) {
        let trees = [peek, wing, expanded].compactMap { $0?.root }
        guard !trees.isEmpty else { return log("present: no view given; nothing sent") }
        guard sendAssets(for: trees) else { return }
        send(.present(
            priority: priority, peek: peek, wing: wing, expanded: expanded,
            opensAt: opensAt, seconds: seconds, dismissIfNotShown: dismissIfNotShown
        ))
    }

    /// Replaces the trees of the current presentation. Sizes stay as presented.
    public func update(peek: ViewNode? = nil, wing: ViewNode? = nil, expanded: ViewNode? = nil) {
        let trees = [peek, wing, expanded].compactMap { $0 }
        guard !trees.isEmpty else { return }
        guard sendAssets(for: trees) else { return }
        send(.update(peek: peek, wing: wing, expanded: expanded))
    }

    /// Gives the notch back.
    public func dismiss() { send(.dismiss) }

    /// Replaces the block's menu actions.
    public func setActions(_ items: [ActionItem]) { send(.actions(items: items)) }

    /// Writes a line to the app's log. Never use stdout.
    public func log(_ text: String) { send(.log(text: text)) }

    // MARK: Runner side

    func send(_ message: BlockToHost) {
        // A closed transport means the app is gone; the runner is ending.
        try? transport.send(message, generation: generation)
    }

    /// A tree over the node limit is refused here, with a log line, so the
    /// app never counts it as a failure.
    private func sendAssets(for trees: [ViewNode]) -> Bool {
        for tree in trees {
            do {
                try tree.validate()
            } catch {
                log("view refused: \(error)")
                return false
            }
        }
        for asset in assets.take(for: trees) {
            send(.asset(id: asset.id, bytes: asset.bytes))
        }
        return true
    }

    /// Handles one message from the app, on the main thread. Calls `start`
    /// once, when the first `welcome` arrives.
    func receive(_ envelope: Envelope<HostToBlock>, start: (Context) -> Void) {
        switch envelope.message {
        case let .welcome(_, settings, dataFolder):
            generation = envelope.generation
            self.settings = settings
            self.dataFolder = URL(fileURLWithPath: dataFolder, isDirectory: true)
            if !started {
                started = true
                start(self)
            }
        case let .event(payload, replay):
            let event = BlockEvent(payload: payload, replay: replay)
            eventHandlers[payload.name]?.forEach { $0(event) }
        case let .owner(owns):
            guard owns != ownsNotch else { return }
            ownsNotch = owns
            ownerHandler?(owns)
        case let .input(input):
            inputHandler?(input)
        case let .action(id):
            actionHandler?(id)
        case let .setting(key, value):
            settings[key] = value
            settingHandler?(key, value)
        case .ping, .quit:
            // Handled by the runner.
            break
        }
    }
}
