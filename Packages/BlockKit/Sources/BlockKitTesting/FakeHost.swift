import BlockKit
import Foundation

/// Plays the app for a block's tests: runs the block over an in-memory
/// transport, records every frame it sends, and sends it messages.
///
/// ```swift
/// let host = FakeHost()
/// let run = host.run(MyBlock())
/// try await host.welcome(settings: ["loud": .bool(true)])
/// try host.send(.event(payload: .pointerHover(.init(isInside: true)), replay: false))
/// let present = await host.waitFor { if case .present = $0 { true } else { false } }
/// ```
public final class FakeHost: @unchecked Sendable {
    // @unchecked: `lock` guards `frames` and `failure`.
    public let generation: Int
    private let appSide: MemoryTransport
    private let blockSide: MemoryTransport
    private let lock = NSLock()
    private var frames: [Envelope<BlockToHost>] = []
    private var failure: (any Error)?

    public init(generation: Int = 1) {
        self.generation = generation
        (appSide, blockSide) = MemoryTransport.pair()
        let stream = appSide.envelopes(of: BlockToHost.self)
        Task { [weak self] in
            do {
                for try await envelope in stream {
                    self?.lock.withLock { self?.frames.append(envelope) }
                }
            } catch {
                self?.lock.withLock { self?.failure = error }
            }
        }
    }

    /// Starts the block. The task ends when the block's runner returns.
    @discardableResult
    public func run(_ block: some Block) -> Task<Void, Never> {
        let runner = Runner(block: block, transport: blockSide, generation: generation)
        return Task { await runner.run() }
    }

    /// Waits for `hello`, then sends `welcome`.
    public func welcome(settings: [String: SettingValue] = [:], dataFolder: String = NSTemporaryDirectory()) async throws {
        _ = await waitFor { if case .hello = $0 { true } else { false } }
        try send(.welcome(contract: Contract.current, settings: settings, dataFolder: dataFolder))
    }

    /// Sends one message to the block, in this host's generation.
    public func send(_ message: HostToBlock) throws {
        try appSide.send(message, generation: generation)
    }

    /// Sends one event numbered `seq`, as a version 2 app does.
    public func event(_ payload: EventPayload, seq: Int, replay: Bool = false) throws {
        try send(.event(payload: payload, replay: replay, seq: seq))
    }

    /// Drops these items on the block's presentation.
    public func drop(_ items: [WireDrop]) throws {
        try send(.input(input: .drop(items: items)))
    }

    /// A click, double-click or menu entry on the `item` with this id.
    public func item(_ id: String, _ action: ItemAction) throws {
        try send(.input(input: .item(id: id, action: action)))
    }

    /// The app started dragging the `item` with this id out.
    public func dragBegan(_ id: String) throws {
        try send(.input(input: .dragBegan(id: id)))
    }

    /// That drag ended.
    public func dragEnded(_ id: String, succeeded: Bool) throws {
        try send(.input(input: .dragEnded(id: id, succeeded: succeeded)))
    }

    /// Closes the connection, as the app does when it quits.
    public func close() { appSide.close() }

    /// Every message the block has sent, in order.
    public var received: [BlockToHost] { lock.withLock { frames.map(\.message) } }

    /// Every frame the block has sent, with generations.
    public var receivedEnvelopes: [Envelope<BlockToHost>] { lock.withLock { frames } }

    /// The paths of each `preview` the block asked for, in order.
    public var previews: [[String]] {
        received.compactMap { if case let .preview(paths) = $0 { paths } else { nil } }
    }

    /// Each `settingNote` the block sent, in order.
    public var notes: [SettingNote] {
        received.compactMap { if case let .settingNote(key, text) = $0 { SettingNote(key: key, text: text) } else { nil } }
    }

    /// The error that ended the block's stream, if a frame did not decode.
    public var streamError: (any Error)? { lock.withLock { failure } }

    /// The first message, received so far or within `timeout`, that matches.
    public func waitFor(timeout: Duration = .seconds(2), _ match: @Sendable (BlockToHost) -> Bool) async -> BlockToHost? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            if let found = received.first(where: match) { return found }
            if clock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits until `timeout` has passed or `count` messages match, and
    /// returns the matching messages.
    public func messages(count: Int, timeout: Duration = .seconds(2), _ match: @Sendable (BlockToHost) -> Bool) async -> [BlockToHost] {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let found = received.filter(match)
            if found.count >= count || clock.now >= deadline { return found }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A `settingNote` a block sent: the note setting's key and its new text.
public struct SettingNote: Hashable, Sendable {
    public var key: String
    public var text: String
    public init(key: String, text: String) {
        self.key = key
        self.text = text
    }
}
