import BlockWire
import Foundation
import NotchCore
import Observation
import os
import SwiftUI

/// Starts one block process: the executable to run and its generation.
/// Returns the transport to it. The real one is `BlockProcess.spawn`; tests
/// return one end of `MemoryTransport.pair()`.
public typealias BlockLauncher = @MainActor (_ executable: URL, _ generation: Int) throws -> any Transport

/// The stand-in for a block that runs in its own process.
///
/// It conforms to `NotchBlock`, so the runtime treats it like any block. It
/// owns the process and translates both ways: app events become `event`
/// frames, and `present`, `update` and `dismiss` frames become calls on the
/// block context. It never holds the runtime; it learns who owns the notch
/// from the read-only `owner` source its creator gives it.
@MainActor
@Observable
public final class RemoteBlock: NotchBlock {
    public let id: BlockID
    public var title: String { manifest.name }
    public var info: BlockInfo {
        BlockInfo(summary: manifest.summary, symbol: manifest.symbol.isEmpty ? "square.grid.2x2" : manifest.symbol,
                  trigger: manifest.trigger, permissions: manifest.permissions,
                  version: manifest.version, source: source)
    }

    /// The trees the block process sent; `NodeView` draws from it.
    public let model = RemoteModel()

    public let manifest: Manifest
    public let packageURL: URL
    public let source: BlockSource

    @ObservationIgnored private let dataFolder: URL
    @ObservationIgnored private let owner: @MainActor () -> BlockID?
    @ObservationIgnored private let launcher: BlockLauncher
    @ObservationIgnored private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "blocks")

    @ObservationIgnored private var context: (any BlockContext)?
    @ObservationIgnored private var transport: (any Transport)?
    @ObservationIgnored private var reader: Task<Void, Never>?
    /// The generation of the current process. Frames carrying another are dropped.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var launchedAt: ContinuousClock.Instant?
    /// True once the current process has said a valid hello and was welcomed.
    @ObservationIgnored private(set) var isWelcomed = false
    /// Events for the current process that arrived before `welcome`, in order.
    @ObservationIgnored private var pending: [EventPayload] = []
    /// The latest event of each kind, with the order it arrived in, for replay.
    @ObservationIgnored private var latest: [WireEvent: (order: Int, payload: EventPayload)] = [:]
    @ObservationIgnored private var eventCount = 0
    /// The ownership the block process was last told.
    @ObservationIgnored private var toldOwns = false
    /// True while an owner observation is armed, so re-activation never arms two.
    @ObservationIgnored private var observingOwner = false

    /// Called by `handleFailure(reason:)`. Supervision attaches here.
    @ObservationIgnored var onFailure: (@MainActor (String) -> Void)?

    /// - Parameters:
    ///   - manifest: the package's manifest, already checked.
    ///   - packageURL: the `.topblock` folder.
    ///   - dataFolder: the folder the block may write to. Created when the block starts.
    ///   - owner: who owns the notch now, read inside observation tracking so
    ///     changes are pushed to the block. Pass `{ runtime.state.owner }`.
    ///   - launcher: starts the process.
    public init(
        manifest: Manifest,
        packageURL: URL,
        source: BlockSource,
        dataFolder: URL,
        owner: @escaping @MainActor () -> BlockID?,
        launcher: @escaping BlockLauncher
    ) {
        self.id = BlockID(rawValue: manifest.id)
        self.manifest = manifest
        self.packageURL = packageURL
        self.source = source
        self.dataFolder = dataFolder
        self.owner = owner
        self.launcher = launcher
    }

    /// The executable the manifest names, inside the package.
    public var executableURL: URL { packageURL.appending(path: manifest.executable) }

    /// The running process's id, when the transport is a real process that
    /// has not exited.
    public var processID: pid_t? {
        guard let process = transport as? BlockProcess, !process.hasExited else { return nil }
        return process.pid
    }

    // MARK: NotchBlock

    public func activate(_ context: any BlockContext) {
        self.context = context
        for name in manifest.events {
            guard let event = try? EventCodec.wireEvent(named: name) else {
                log.error("\(self.id.rawValue, privacy: .public): unknown event \(name, privacy: .public) ignored")
                continue
            }
            EventCodec.subscribe(event, in: context) { [weak self] payload in self?.received(payload) }
        }
        if !observingOwner { observeOwner() }
        launch()
    }

    public func deactivate() {
        context = nil
        endProcess(wait: false)
        latest = [:]
        model.clear()
    }

    /// Ends the process now and waits for it to exit. For app quit.
    public func stop() {
        endProcess(wait: true)
    }

    // MARK: Process

    /// Ends the current process and starts a new one, which gets the latest
    /// event of each kind as a replay.
    func restart() {
        endProcess(wait: false)
        launch()
    }

    private func launch() {
        generation += 1
        isWelcomed = false
        toldOwns = false
        pending = latest.values.sorted { $0.order < $1.order }.map(\.payload)
        launchedAt = .now
        let transport: any Transport
        do {
            transport = try launcher(executableURL, generation)
        } catch {
            return handleFailure(reason: "\(manifest.name) could not start: \(error)")
        }
        self.transport = transport
        let generation = self.generation
        reader = BlockProcess.readFrames(
            from: transport,
            deliver: { [weak self] envelope in self?.receive(envelope, from: generation) },
            ended: { [weak self] error in self?.transportEnded(error, generation: generation) }
        )
    }

    /// Sends `quit` and closes the transport. Frames still in flight from
    /// this process are dropped.
    private func endProcess(wait: Bool) {
        reader?.cancel()
        reader = nil
        isWelcomed = false
        pending = []
        guard let transport else { return }
        self.transport = nil
        try? transport.send(HostToBlock.quit, generation: generation)
        if wait, let process = transport as? BlockProcess {
            process.terminate()
        } else {
            transport.close()
        }
    }

    private func transportEnded(_ error: (any Error)?, generation: Int) {
        guard generation == self.generation, transport != nil else { return }
        if let error {
            handleFailure(reason: "\(manifest.name) sent a bad frame: \(error)")
        } else {
            handleFailure(reason: "\(manifest.name) stopped unexpectedly")
        }
    }

    /// Every failure of the block process comes through here: it did not
    /// start, ended, sent a bad frame or tree, or speaks an unsupported
    /// contract. The presentation is withdrawn and the process ended.
    /// Restarting and turning off are decided by supervision, which attaches
    /// through `onFailure`.
    func handleFailure(reason: String) {
        log.error("\(self.id.rawValue, privacy: .public) failed: \(reason, privacy: .public)")
        context?.dismiss()
        endProcess(wait: false)
        onFailure?(reason)
    }

    // MARK: Frames from the block

    private func receive(_ envelope: Envelope<BlockToHost>, from generation: Int) {
        // A frame from an earlier process, or a frame that claims another generation.
        guard generation == self.generation, envelope.generation == self.generation, transport != nil else { return }
        switch envelope.message {
        case let .hello(contract, blockID, version):
            hello(contract: contract, blockID: blockID, version: version)
        case let .present(priority, peek, wing, expanded, opensAt, seconds, dismissIfNotShown):
            guard isWelcomed else { return }
            present(priority: priority, peek: peek, wing: wing, expanded: expanded,
                    opensAt: opensAt, seconds: seconds, dismissIfNotShown: dismissIfNotShown)
        case let .update(peek, wing, expanded):
            guard isWelcomed, validate([peek, wing, expanded]) else { return }
            model.setTrees(peek: peek, wing: wing, expanded: expanded)
        case .dismiss:
            context?.dismiss()
        case let .asset(assetID, bytes):
            model.storeAsset(id: assetID, bytes: bytes)
        case let .log(text):
            log.info("\(self.id.rawValue, privacy: .public): \(text, privacy: .public)")
        case .pong, .actions:
            // Heartbeat and menu actions come with supervision and actions.
            break
        }
    }

    private func hello(contract: Int, blockID: String, version: String) {
        guard !isWelcomed else { return }
        guard Contract.supported.contains(contract) else {
            let supported = Contract.supported.lowerBound == Contract.supported.upperBound
                ? "contract \(Contract.supported.lowerBound)"
                : "contracts \(Contract.supported.lowerBound) to \(Contract.supported.upperBound)"
            return handleFailure(reason: "\(manifest.name) speaks contract \(contract); this app supports \(supported)")
        }
        if let launchedAt {
            let elapsed = launchedAt.duration(to: .now)
            log.info("\(self.id.rawValue, privacy: .public) \(version, privacy: .public) said hello after \(elapsed, privacy: .public), generation \(self.generation)")
        }
        try? FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        send(.welcome(contract: Contract.current, settings: defaultSettings(), dataFolder: dataFolder.path))
        isWelcomed = true
        for payload in pending {
            send(.event(payload: payload, replay: true))
        }
        pending = []
        pushOwner()
    }

    private func present(
        priority: Priority, peek: ViewSlot?, wing: ViewSlot?, expanded: ViewSlot?,
        opensAt: Level, seconds: Double?, dismissIfNotShown: Bool
    ) {
        guard let context else { return }
        guard peek != nil || wing != nil || expanded != nil else {
            return log.error("\(self.id.rawValue, privacy: .public): present with no view ignored")
        }
        guard validate([peek?.root, wing?.root, expanded?.root]) else { return }
        model.setTrees(peek: peek?.root, wing: wing?.root, expanded: expanded?.root)

        let model = self.model
        func content(_ slot: ViewSlot?, _ which: RemoteSlot) -> NotchContent? {
            slot.map { slot in
                NotchContent(size: CGSize(width: slot.width, height: slot.height)) {
                    // Button input reaches the block with input forwarding.
                    RemoteSlotView(model: model, slot: which)
                }
            }
        }
        context.present(Presentation(
            priority: Self.priority(priority),
            peek: content(peek, .peek),
            wing: content(wing, .wing),
            expanded: content(expanded, .expanded),
            opensAt: opensAt == .expanded ? .expanded : .peek,
            duration: seconds.map { Duration.seconds($0) }
        ))
        // Exactly what an in-app block does to answer a change just made:
        // shown later it would answer nothing, so it does not wait.
        if dismissIfNotShown, !context.ownsNotch { context.dismiss() }
    }

    /// False, after reporting a failure, when a tree is over the node limit.
    private func validate(_ trees: [ViewNode?]) -> Bool {
        for tree in trees.compactMap({ $0 }) {
            do {
                try tree.validate()
            } catch {
                handleFailure(reason: "\(manifest.name) sent a view that is too large: \(error)")
                return false
            }
        }
        return true
    }

    private static func priority(_ priority: Priority) -> PresentationPriority {
        switch priority {
        case .ambient: .ambient
        case .standard: .standard
        case .interactive: .interactive
        }
    }

    // MARK: Messages to the block

    private func send(_ message: HostToBlock) {
        // A closed transport ends the reader, which reports the failure.
        try? transport?.send(message, generation: generation)
    }

    private func received(_ payload: EventPayload) {
        eventCount += 1
        latest[payload.name] = (eventCount, payload)
        if isWelcomed {
            send(.event(payload: payload, replay: false))
        } else if transport != nil {
            pending.append(payload)
        }
    }

    /// Each declared setting's default. Toggles with no default are on.
    // Manifest defaults only; stored values arrive with the settings form.
    private func defaultSettings() -> [String: SettingValue] {
        var values: [String: SettingValue] = [:]
        for spec in manifest.settings {
            switch spec.type {
            case .toggle: values[spec.key] = spec.default ?? .bool(true)
            case .choice: if let value = spec.default { values[spec.key] = value }
            case .note: break
            }
        }
        return values
    }

    // MARK: Ownership

    /// Reads the owner inside observation tracking and re-arms on each change.
    private func observeOwner() {
        observingOwner = true
        _ = withObservationTracking {
            owner()
        } onChange: { [weak self] in
            // Runs before the change lands; read the new value after it.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.context != nil else {
                    self.observingOwner = false
                    return
                }
                self.observeOwner()
                self.pushOwner()
            }
        }
    }

    private func pushOwner() {
        guard isWelcomed else { return }
        let owns = owner() == id
        guard owns != toldOwns else { return }
        toldOwns = owns
        send(.owner(owns: owns))
    }
}
