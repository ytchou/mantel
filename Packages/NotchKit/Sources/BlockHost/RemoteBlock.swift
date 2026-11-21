import BlockWire
import Foundation
import NotchCore
import Observation
import os
import SwiftUI

/// Starts one block process: the executable to run and its generation.
/// Returns the transport to it. Tests return one end of
/// `MemoryTransport.pair()`. A stand-in without one starts its block
/// sandboxed, with `BlockProcess.spawn(executable:generation:sandbox:)`.
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
                  // The access the sandbox grants, in the user's words, after
                  // what the author wrote: the Blocks page shows both.
                  trigger: manifest.trigger, permissions: manifest.permissions + manifest.accessText,
                  version: manifest.version, source: source)
    }

    /// The trees the block process sent; `NodeView` draws from it.
    public let model = RemoteModel()

    /// Changes only when an update swaps the package in place.
    public private(set) var manifest: Manifest
    public let packageURL: URL
    public private(set) var source: BlockSource

    /// Whether the block runs as it should. Observed, so the Blocks page redraws.
    public private(set) var health: BlockHealth
    /// The menu actions the current process offered last. Empty until it
    /// offers some, and after it fails.
    public private(set) var actions: [BlockAction] = []
    /// Each declared setting's current value: stored, or the manifest default.
    public private(set) var settings: [String: SettingValue] = [:]
    /// The text the block set for its `note` settings with `settingNote`,
    /// by key. A note without one shows its manifest title.
    public private(set) var notes: [String: String] = [:]

    @ObservationIgnored private let dataFolder: URL
    /// The app's temporary folder. The block's sandbox closes its `TopNotch`
    /// subtree, except for `temporaryFolder` inside it.
    @ObservationIgnored private let sharedTemporaryFolder: URL
    /// Where the shell writes promised files of a drop.
    @ObservationIgnored private let dropFolder: URL
    @ObservationIgnored private let owner: @MainActor () -> BlockID?
    @ObservationIgnored private let launcher: BlockLauncher?
    @ObservationIgnored private let screenshotFolder: @MainActor () -> URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: BlockClock
    @ObservationIgnored private let turnOff: @MainActor (BlockID) -> Void
    @ObservationIgnored private let preview: @MainActor ([URL]) -> Void
    @ObservationIgnored private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "blocks")

    @ObservationIgnored private var context: (any BlockContext)?
    @ObservationIgnored private var transport: (any Transport)?
    @ObservationIgnored private var reader: Task<Void, Never>?
    /// The generation of the current process. Frames carrying another are dropped.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var launchedAt: ContinuousClock.Instant?
    /// True once the current process has said a valid hello and was welcomed.
    @ObservationIgnored private(set) var isWelcomed = false
    /// The contract version the current process said in `hello`. Version 2
    /// messages go only to a version 2 block.
    @ObservationIgnored private var contract = 1
    /// The `seq` of the last event sent; one counter per stand-in.
    @ObservationIgnored private var eventSeq = 0
    /// When each of the last `sentTimesKept` events was sent, on `clock`, by `seq`.
    @ObservationIgnored private var sentTimes: [Int: Duration] = [:]
    /// Events for the current process to send at `welcome`, in order: the
    /// replay of `latest` from the launch, then live events that arrived since.
    @ObservationIgnored private var pending: [(payload: EventPayload, replay: Bool)] = []
    /// The latest event of each kind (for `nowPlaying`, of each player), with
    /// the order it arrived in, for replay.
    @ObservationIgnored private var latest: [ReplayKey: (order: Int, payload: EventPayload)] = [:]
    @ObservationIgnored private var eventCount = 0
    /// The ownership the block process was last told.
    @ObservationIgnored private var toldOwns = false
    /// True while an owner observation is armed, so re-activation never arms two.
    @ObservationIgnored private var observingOwner = false
    /// Events subscribed to in the current context; an update adds new ones
    /// and, when it drops some, subscribes again from scratch.
    @ObservationIgnored private var subscribed: Set<WireEvent> = []
    /// The screenshot folder the current process's sandbox opens, for
    /// `files.screenshots`; nil without that access.
    @ObservationIgnored private var launchedScreenshotFolder: URL?

    /// Called by `handleFailure(reason:)` with the reason, before supervision decides.
    @ObservationIgnored var onFailure: (@MainActor (String) -> Void)?

    // Supervision.
    @ObservationIgnored private var supervisor = Supervisor()
    /// Restarts since the user last turned the block on, in this app run.
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var pingSeq = 0
    /// The `seq` of the latest pong from the current process.
    @ObservationIgnored private(set) var lastPong = 0
    /// When the current process last answered, or started, on `clock`.
    @ObservationIgnored private var lastAnswer: Duration = .zero

    /// - Parameters:
    ///   - manifest: the package's manifest, already checked.
    ///   - packageURL: the `.topblock` folder.
    ///   - dataFolder: the folder the block may write to. Created at each launch of its process.
    ///   - owner: who owns the notch now, read inside observation tracking so
    ///     changes are pushed to the block. Pass `{ runtime.state.owner }`.
    ///   - launcher: starts the process. Nil starts it under the sandbox
    ///     profile built from the manifest's `access`.
    ///   - screenshotFolder: the folder `files.screenshots` opens, read at
    ///     each start; the app passes the folder the screenshot watcher uses.
    ///   - defaults: where the block's settings (`<id>.<key>`) and the reason
    ///     it was turned off (`block.<id>.failure`) are stored.
    ///   - clock: times the heartbeat and failures. Must stop while the Mac sleeps.
    ///   - turnOff: turns the block off after repeated failures. The app
    ///     passes a closure that calls `BlockSettings.setEnabled(id, false, in:)`.
    ///   - preview: shows files in Quick Look, for the block's `preview`.
    ///     Nil uses the system Quick Look panel.
    ///   - sharedTemporaryFolder: the app's temporary folder. The block's own
    ///     temporary folder is `<it>/TopNotch/Blocks/<id>/`. Tests pass their own.
    ///   - dropFolder: where the shell writes promised files of a drop;
    ///     dropped files inside it are moved into the block's own temporary
    ///     folder. Tests pass their own.
    public init(
        manifest: Manifest,
        packageURL: URL,
        source: BlockSource,
        dataFolder: URL,
        owner: @escaping @MainActor () -> BlockID?,
        launcher: BlockLauncher? = nil,
        screenshotFolder: @escaping @MainActor () -> URL? = { nil },
        defaults: UserDefaults = .standard,
        clock: BlockClock = .suspending,
        turnOff: @escaping @MainActor (BlockID) -> Void = { _ in },
        preview: (@MainActor ([URL]) -> Void)? = nil,
        sharedTemporaryFolder: URL = FileManager.default.temporaryDirectory,
        dropFolder: URL = DropFolder.root
    ) {
        let id = BlockID(rawValue: manifest.id)
        self.id = id
        self.manifest = manifest
        self.packageURL = packageURL
        self.source = source
        self.dataFolder = dataFolder
        self.sharedTemporaryFolder = sharedTemporaryFolder
        self.dropFolder = dropFolder
        self.owner = owner
        self.launcher = launcher
        self.screenshotFolder = screenshotFolder
        self.defaults = defaults
        self.clock = clock
        self.turnOff = turnOff
        self.preview = preview ?? { FilePreview.shared.show($0) }
        // Turned off after failures, and not yet turned on again.
        health = defaults.string(forKey: Self.failureKey(id)).map { .turnedOff(reason: $0) } ?? .ok
        settings = readSettings()
        wireItemCallbacks()
        model.mayDragFile = { [weak self] path in self?.readablePaths([path]).isEmpty == false }
    }

    /// Where the reason for the last turn-off is stored.
    static func failureKey(_ id: BlockID) -> String { "block.\(id.rawValue).failure" }

    /// The block's own temporary folder and `TMPDIR`, inside the app's:
    /// `<shared>/TopNotch/Blocks/<id>/`. Created at each launch of its
    /// process. Only this block's sandbox opens it.
    var temporaryFolder: URL {
        sharedTemporaryFolder.appending(path: "TopNotch/Blocks/\(id.rawValue)", directoryHint: .isDirectory)
    }

    /// The executable the manifest names, inside the package.
    public var executableURL: URL { PackageValidator.executableFolder(in: packageURL).appending(path: manifest.executable) }

    /// The running process's id, when the transport is a real process that
    /// has not exited.
    public var processID: pid_t? {
        guard let process = transport as? BlockProcess, !process.hasExited else { return nil }
        return process.pid
    }

    // MARK: NotchBlock

    public func activate(_ context: any BlockContext) {
        self.context = context
        // Turned on, by the user or at launch: earlier failures no longer count.
        defaults.removeObject(forKey: Self.failureKey(id))
        supervisor.reset()
        restarts = 0
        health = .ok
        subscribed = []
        subscribeToManifestEvents()
        if !observingOwner { observeOwner() }
        launch()
    }

    /// Subscribes to each manifest event not yet subscribed in this context.
    private func subscribeToManifestEvents() {
        guard let context else { return }
        for name in manifest.events {
            guard let event = try? EventCodec.wireEvent(named: name) else {
                log.error("\(self.id.rawValue, privacy: .public): unknown event \(name, privacy: .public) ignored")
                continue
            }
            guard subscribed.insert(event).inserted else { continue }
            EventCodec.subscribe(event, in: context) { [weak self] payload in self?.received(payload) }
        }
    }

    public func deactivate() {
        context = nil
        endProcess()?.close()
        latest = [:]
        actions = []
        notes = [:]
        model.clear()
    }

    /// Forwards a click, and to a version 2 block a drop, while this block
    /// owns the notch. The runtime passes only drops of kinds the
    /// presentation `accepts`. Dropped files in the drop folder are moved
    /// into the block's own temporary folder first; see `forwardedDrop`.
    public func handle(_ input: NotchInput) {
        guard context?.ownsNotch == true, isWelcomed else { return }
        switch input {
        case .click:
            send(.input(input: .click))
        case let .drop(items):
            guard contract >= 2 else { return }
            let forwarded = items.compactMap { forwardedDrop($0) }
            guard !forwarded.isEmpty else { return }
            send(.input(input: .drop(items: forwarded)))
        }
    }

    /// `item` as the block gets it. A file inside the drop folder, which the
    /// block's sandbox cannot read, is moved to
    /// `<temporaryFolder>/TopNotch/Drops/<path below the drop folder>` (its
    /// `<uuid>` folder keeps names apart) and sent with that path. Inside the
    /// block its own temporary folder is `TMPDIR`. Any other item passes
    /// unchanged. Nil, with a log line, when the move fails.
    // Moves on the main actor: a rename inside one volume, so it is quick.
    // If drops ever cross volumes, move off the main actor before sending.
    private func forwardedDrop(_ item: DroppedItem) -> WireDrop? {
        guard case let .file(url) = item else { return Self.wireDrop(item) }
        let root = Self.resolvedPath(dropFolder)
        let source = Self.resolvedPath(url)
        guard source.hasPrefix(root + "/") else { return Self.wireDrop(item) }
        let relative = String(source.dropFirst(root.count + 1))
        let target = temporaryFolder.appending(path: "TopNotch/Drops", directoryHint: .isDirectory)
            .appending(path: relative, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            log.error("\(self.id.rawValue, privacy: .public): dropped file \(source, privacy: .private) not moved, left out: \(error, privacy: .public)")
            return nil
        }
        return .file(path: target.path)
    }

    static func wireDrop(_ item: DroppedItem) -> WireDrop {
        switch item {
        case let .file(url): .file(path: url.path)
        case let .link(url): .link(url: url.absoluteString)
        case let .text(text): .text(string: text)
        }
    }

    /// Routes the item layer's clicks, menu entries and drags to `input`
    /// frames. `dragBegan` is sent in the main-actor turn that starts the
    /// dragging session, so it reaches the block before the drag monitor's
    /// `dragStarted`: both go down the same socket.
    private func wireItemCallbacks() {
        model.onItemAction = { [weak self] id, action in self?.sendItemInput(.item(id: id, action: action)) }
        model.onDragBegan = { [weak self] id in self?.sendItemInput(.dragBegan(id: id)) }
        model.onDragEnded = { [weak self] id, succeeded in self?.sendItemInput(.dragEnded(id: id, succeeded: succeeded)) }
    }

    private func sendItemInput(_ input: WireInput) {
        guard isWelcomed, contract >= 2 else { return }
        send(.input(input: input))
    }

    /// The block's settings drawn from its manifest, or nil when it declares none.
    public var settingsPane: AnyView? {
        manifest.settings.isEmpty ? nil : AnyView(SettingsForm(block: self))
    }

    /// Withdraws the presentation and ends the process without waiting for
    /// it: it is signalled, and reaped, off the main thread. For update and
    /// remove.
    public func stop() {
        withdraw()
        endProcess()?.close()
    }

    /// Ends the processes of every block in `blocks` together and waits for
    /// them: at most about 2.5 s in total, however many there are. For app
    /// quit, where waiting is the point.
    public static func stopAll(_ blocks: [RemoteBlock]) {
        var processes: [BlockProcess] = []
        for block in blocks {
            block.withdraw()
            guard let transport = block.endProcess() else { continue }
            if let process = transport as? BlockProcess {
                processes.append(process)
            } else {
                transport.close()
            }
        }
        BlockProcess.terminate(processes)
    }

    /// Takes the manifest of the package now at `packageURL`, after an update
    /// replaced the folder, and starts the block again if it is on. The
    /// stand-in keeps its place in the runtime; settings are read again.
    /// Call `stop()` before replacing the folder. Also used with the old
    /// manifest to start the old version again when the replacement failed.
    /// The old process is ended without waiting; its late frames are dropped.
    func replacePackage(manifest: Manifest, source: BlockSource) {
        withdraw()
        endProcess()?.close()
        self.manifest = manifest
        self.source = source
        settings = readSettings()
        notes = [:]
        guard let context else { return }
        // An update that drops events ends every subscription and makes them
        // again, so the runtime no longer counts this block for the dropped
        // ones and their sources can stop.
        let events = Set(manifest.events.compactMap(WireEvent.init(rawValue:)))
        if !subscribed.isSubset(of: events) {
            context.unsubscribeAll()
            subscribed = []
        }
        subscribeToManifestEvents()
        launch()
    }

    // MARK: Process

    private func launch() {
        generation += 1
        isWelcomed = false
        contract = 1
        toldOwns = false
        // Only events this version listens to; an update may drop some.
        pending = latest.values.sorted { $0.order < $1.order }.map(\.payload)
            .filter { manifest.events.contains($0.name.rawValue) }
            .map { ($0, true) }
        launchedAt = .now
        pingSeq = 0
        lastPong = 0
        lastAnswer = clock.now()
        launchedScreenshotFolder = manifest.access.contains(.filesScreenshots) ? screenshotFolder() : nil
        let transport: any Transport
        do {
            // Before the process starts, for both paths: the sandbox profile
            // names real paths, the block is told the data folder at
            // `welcome`, and drops are moved into the temporary folder.
            try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
            if let launcher {
                transport = try launcher(executableURL, self.generation)
            } else {
                transport = try spawnSandboxed()
            }
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
        heartbeat = BlockProcess.heartbeat(clock: clock) { [weak self] in
            self?.heartbeatTick(generation: generation) ?? false
        }
    }

    /// Starts the block under the sandbox profile its manifest asks for.
    /// `launch` has created the data and temporary folders: the profile
    /// names real paths. The temporary folder is the block's own, inside the
    /// app's `TopNotch` subtree, which the profile closes: other blocks'
    /// temporary files and dropped files stay out of reach. Dropped files
    /// reach the block by `forwardedDrop`.
    private func spawnSandboxed() throws -> any Transport {
        let profile = SandboxProfile(
            network: manifest.access.contains(.network),
            readsHome: manifest.access.contains(.filesRead),
            screenshotFolder: launchedScreenshotFolder,
            package: packageURL,
            dataFolder: dataFolder,
            temporaryFolder: temporaryFolder,
            sharedTemporaryFolder: sharedTemporaryFolder,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        return try BlockProcess.spawn(executable: executableURL, generation: generation, sandbox: profile)
    }

    /// One heartbeat step: a hang when the process has not answered for
    /// `hangAfter` (`startAllowance` before `welcome`), otherwise the next
    /// ping. False ends the heartbeat.
    private func heartbeatTick(generation: Int) -> Bool {
        guard generation == self.generation, transport != nil else { return false }
        let limit = isWelcomed ? BlockProcess.hangAfter : BlockProcess.startAllowance
        if clock.now() - lastAnswer >= limit {
            handleFailure(reason: "\(manifest.name) stopped answering")
            return false
        }
        pingSeq += 1
        send(.ping(seq: pingSeq))
        return true
    }

    /// Stops reading and pinging the current process, sends it `quit` and
    /// lets it go. Returns its transport, still open, for the caller to close
    /// or to wait on. Frames still in flight from this process are dropped.
    private func endProcess() -> (any Transport)? {
        reader?.cancel()
        reader = nil
        heartbeat?.cancel()
        heartbeat = nil
        isWelcomed = false
        pending = []
        guard let transport else { return nil }
        self.transport = nil
        try? transport.send(HostToBlock.quit, generation: generation)
        return transport
    }

    /// Withdraws what the block shows: its presentation, its menu actions
    /// and the trees and images it sent.
    private func withdraw() {
        context?.dismiss()
        actions = []
        model.clear()
    }

    private func transportEnded(_ error: (any Error)?, generation: Int) {
        guard generation == self.generation, transport != nil else { return }
        if let error = error as? TransportError, case .overflow = error {
            handleFailure(reason: "\(manifest.name) sent more than the app could read")
        } else if let error {
            handleFailure(reason: "\(manifest.name) sent a bad frame: \(error)")
        } else {
            handleFailure(reason: "\(manifest.name) stopped unexpectedly")
        }
    }

    /// Every failure of the block process comes through here: it did not
    /// start, ended, sent a bad frame or tree, stopped answering pings, or
    /// speaks an unsupported contract. The presentation is withdrawn, the
    /// actions and view cleared and the process ended; then `Supervisor`
    /// decides between a new process at once and turning the block off.
    func handleFailure(reason: String) {
        log.error("\(self.id.rawValue, privacy: .public) failed: \(reason, privacy: .public)")
        withdraw()
        endProcess()?.close()
        onFailure?(reason)
        // Turned off meanwhile: nothing to restart.
        guard context != nil else { return }

        switch supervisor.failed(at: clock.now()) {
        case .restart:
            restarts += 1
            health = .restarting(count: restarts)
            log.info("\(self.id.rawValue, privacy: .public) restart \(self.restarts)")
            launch()
        case .turnOff:
            supervisor.reset()
            let sentence = "It stopped \(Supervisor.limit) times in a minute. Last reason: \(Self.sentenceEnd(reason))"
            defaults.set(sentence, forKey: Self.failureKey(id))
            health = .turnedOff(reason: sentence)
            log.error("\(self.id.rawValue, privacy: .public) turned off: \(sentence, privacy: .public)")
            turnOff(id)
        }
    }

    /// `reason` as the end of a sentence: one full stop.
    private static func sentenceEnd(_ reason: String) -> String {
        reason.hasSuffix(".") ? reason : reason + "."
    }

    // MARK: Frames from the block

    private func receive(_ envelope: Envelope<BlockToHost>, from generation: Int) {
        // A frame from an earlier process, or a frame that claims another generation.
        guard generation == self.generation, envelope.generation == self.generation, transport != nil else { return }
        switch envelope.message {
        case let .hello(contract, blockID, version):
            hello(contract: contract, blockID: blockID, version: version)
        case let .present(priority, peek, wing, expanded, opensAt, seconds, dismissIfNotShown, accepts, answering):
            guard isWelcomed else { return }
            if dismissIfNotShown, let answering, isLate(answering) {
                return log.info("\(self.id.rawValue, privacy: .public): present answering event \(answering) dropped: older than \(Self.answerWindow, privacy: .public)")
            }
            present(priority: priority, peek: peek, wing: wing, expanded: expanded,
                    opensAt: opensAt, seconds: seconds, dismissIfNotShown: dismissIfNotShown, accepts: accepts ?? [])
        case let .update(peek, wing, expanded):
            guard isWelcomed, validate([peek, wing, expanded]) else { return }
            model.setTrees(peek: peek, wing: wing, expanded: expanded)
        case .dismiss:
            guard isWelcomed else { return }
            context?.dismiss()
        case let .asset(assetID, bytes):
            model.storeAsset(id: assetID, bytes: bytes)
        case let .log(text):
            log.info("\(self.id.rawValue, privacy: .public): \(text, privacy: .public)")
        case let .pong(seq):
            guard seq > 0, seq <= pingSeq else { return }
            lastPong = max(lastPong, seq)
            lastAnswer = clock.now()
        case let .actions(items):
            guard isWelcomed else { return }
            let generation = self.generation
            actions = items.map { item in
                BlockAction(id: item.id, title: item.title, isEnabled: item.enabled) { [weak self] in
                    self?.perform(item.id, offeredBy: generation)
                }
            }
        case let .preview(paths):
            guard isWelcomed else { return }
            let urls = readablePaths(paths).map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty { preview(urls) }
        case let .settingNote(key, text):
            guard isWelcomed, manifest.settings.contains(where: { $0.key == key && $0.type == .note }) else { return }
            notes[key] = text
        }
    }

    /// Sends a menu action, only to the process that offered it.
    private func perform(_ actionID: String, offeredBy generation: Int) {
        guard generation == self.generation, isWelcomed else { return }
        send(.action(id: actionID))
    }

    /// A `button` node in the block's view was clicked.
    func buttonTapped(_ buttonID: String) {
        guard isWelcomed else { return }
        send(.input(input: .button(id: buttonID)))
    }

    private func hello(contract: Int, blockID: String, version: String) {
        guard !isWelcomed else { return }
        guard Contract.supported.contains(contract) else {
            let supported = Contract.supported.lowerBound == Contract.supported.upperBound
                ? "contract \(Contract.supported.lowerBound)"
                : "contracts \(Contract.supported.lowerBound) to \(Contract.supported.upperBound)"
            return handleFailure(reason: "\(manifest.name) speaks contract \(contract); this app supports \(supported)")
        }
        guard blockID == manifest.id else {
            return handleFailure(reason: "\(manifest.name) says it is \(blockID), but its manifest says \(manifest.id)")
        }
        if version != manifest.version {
            log.info("\(self.id.rawValue, privacy: .public) says version \(version, privacy: .public); its manifest says \(self.manifest.version, privacy: .public)")
        }
        if let launchedAt {
            let elapsed = launchedAt.duration(to: .now)
            log.info("\(self.id.rawValue, privacy: .public) \(version, privacy: .public) said hello after \(elapsed, privacy: .public), generation \(self.generation)")
        }
        settings = readSettings()
        self.contract = contract
        send(.welcome(contract: Contract.current, settings: settings, dataFolder: dataFolder.path))
        isWelcomed = true
        // The hang limit runs from here, no longer from the launch.
        lastAnswer = clock.now()
        for event in pending {
            sendEvent(event.payload, replay: event.replay)
        }
        pending = []
        pushOwner()
    }

    private func present(
        priority: Priority, peek: ViewSlot?, wing: ViewSlot?, expanded: ViewSlot?,
        opensAt: Level, seconds: Double?, dismissIfNotShown: Bool, accepts: [DragStarted.Kind]
    ) {
        guard let context else { return }
        guard peek != nil || wing != nil || expanded != nil else {
            return log.error("\(self.id.rawValue, privacy: .public): present with no view ignored")
        }
        guard validate([peek?.root, wing?.root, expanded?.root]) else { return }
        model.setTrees(peek: peek?.root, wing: wing?.root, expanded: expanded?.root)

        let model = self.model
        let onButton: @MainActor (String) -> Void = { [weak self] buttonID in self?.buttonTapped(buttonID) }
        func content(_ slot: ViewSlot?, _ which: RemoteSlot) -> NotchContent? {
            slot.map { slot in
                NotchContent(size: CGSize(width: slot.width, height: slot.height)) {
                    RemoteSlotView(model: model, slot: which, onButton: onButton)
                }
            }
        }
        context.present(Presentation(
            priority: Self.priority(priority),
            peek: content(peek, .peek),
            wing: content(wing, .wing),
            expanded: content(expanded, .expanded),
            opensAt: opensAt == .expanded ? .expanded : .peek,
            duration: seconds.flatMap(Self.duration(seconds:)),
            accepts: Set(accepts.map(Self.dropKind))
        ))
        // Exactly what an in-app block does to answer a change just made:
        // shown later it would answer nothing, so it does not wait.
        if dismissIfNotShown, !context.ownsNotch { context.dismiss() }
    }

    /// The longest presentation a block may ask for, in seconds.
    static let maxSeconds = 3600.0

    /// A presentation's time from the block's `seconds`: nil (until dismissed)
    /// when it is not finite or not positive, and at most `maxSeconds`.
    static func duration(seconds: Double) -> Duration? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        return .seconds(min(seconds, maxSeconds))
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

    private static func dropKind(_ kind: DragStarted.Kind) -> DropKind {
        switch kind {
        case .file: .file
        case .link: .link
        case .text: .text
        }
    }

    // MARK: Late answers

    /// How old the event a `present` answers may be, when the present has
    /// `dismissIfNotShown`. Shown later than this it would answer nothing
    /// the user still sees, so it is dropped. A present without
    /// `dismissIfNotShown` is never dropped (a rename result may take 20 s).
    static let answerWindow: Duration = .seconds(2)
    /// How many events' send times are kept to judge late answers.
    static let sentTimesKept = 32

    /// True when event `seq` was sent more than `answerWindow` ago, or so
    /// long ago that its time is no longer kept. A `seq` never sent is not late.
    private func isLate(_ seq: Int) -> Bool {
        guard seq > 0, seq <= eventSeq else { return false }
        guard let sent = sentTimes[seq] else { return true }
        return clock.now() - sent > Self.answerWindow
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

    /// Sends an event, numbered for a version 2 block, and keeps its send time.
    private func sendEvent(_ payload: EventPayload, replay: Bool) {
        guard contract >= 2 else { return send(.event(payload: payload, replay: replay)) }
        eventSeq += 1
        sentTimes[eventSeq] = clock.now()
        sentTimes[eventSeq - Self.sentTimesKept] = nil
        send(.event(payload: payload, replay: replay, seq: eventSeq))
    }

    private func received(_ payload: EventPayload) {
        // A subscription kept from before an update that dropped this event.
        guard manifest.events.contains(payload.name.rawValue) else { return }
        if case .screenshotCaptured = payload, screenshotFolderMoved() {
            // The sandbox opens the folder the process started with; a block
            // told of a screenshot elsewhere could not rename it. A new process
            // gets the new folder; this event waits for its `welcome`.
            log.info("\(self.id.rawValue, privacy: .public): screenshot folder changed, restarting")
            withdraw()
            endProcess()?.close()
            launch()
        }
        remember(payload)
        if isWelcomed {
            sendEvent(payload, replay: false)
        } else if transport != nil {
            // Live, though it waits for `welcome`.
            pending.append((payload, false))
        }
    }

    /// True when a process is running under `files.screenshots` and the
    /// screenshot folder is no longer the one it was started with.
    private func screenshotFolderMoved() -> Bool {
        guard transport != nil, manifest.access.contains(.filesScreenshots) else { return false }
        return screenshotFolder()?.standardizedFileURL != launchedScreenshotFolder?.standardizedFileURL
    }

    // MARK: Paths the block may show

    /// The paths of `paths` the block's sandbox could read, for `preview`
    /// and for the files of an item drag-out, as `SandboxProfile` sets it:
    /// inside its data folder, its own temporary folder, its package, or,
    /// with `files.screenshots`, the screenshot folder its process started
    /// with; never elsewhere in the app's `TopNotch` temporary subtree (other
    /// blocks' files, dropped files); otherwise inside the app's temporary
    /// folder, or any absolute path with `files.read`. Compared with symbolic
    /// links followed. Dropped paths are logged.
    func readablePaths(_ paths: [String]) -> [String] {
        let readsAll = manifest.access.contains(.filesRead)
        let own = ([dataFolder, temporaryFolder, packageURL]
            + [launchedScreenshotFolder].compactMap { $0 }).map(Self.resolvedPath)
        let closed = Self.resolvedPath(SandboxProfile.appTemporaryFolder(in: sharedTemporaryFolder))
        let shared = Self.resolvedPath(sharedTemporaryFolder)
        func isInside(_ target: String, _ root: String) -> Bool { target == root || target.hasPrefix(root + "/") }
        return paths.filter { path in
            guard path.hasPrefix("/") else {
                log.error("\(self.id.rawValue, privacy: .public): relative path dropped: \(path, privacy: .private)")
                return false
            }
            let target = Self.resolvedPath(URL(fileURLWithPath: path))
            let allowed = own.contains { isInside(target, $0) }
                || (!isInside(target, closed) && (readsAll || isInside(target, shared)))
            if !allowed {
                log.error("\(self.id.rawValue, privacy: .public): path outside what its sandbox reads dropped: \(path, privacy: .private)")
            }
            return allowed
        }
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Replay

    /// What one replayed event stands for: its kind, and for `nowPlaying` the
    /// player, since each player has its own state.
    struct ReplayKey: Hashable {
        let name: WireEvent
        let detail: String

        init(_ payload: EventPayload) {
            name = payload.name
            if case let .nowPlaying(value) = payload { detail = value.player } else { detail = "" }
        }
    }

    /// The most events of one kind kept for replay.
    static let replayLimit = 8

    /// Keeps `payload` as the latest of its key. Over `replayLimit` for its
    /// kind, the oldest player that no longer plays is forgotten first: a
    /// block that never saw it play ends in the same state without it.
    private func remember(_ payload: EventPayload) {
        eventCount += 1
        let key = ReplayKey(payload)
        latest[key] = (eventCount, payload)
        let sameKind = latest.filter { $0.key.name == key.name }.sorted { $0.value.order < $1.value.order }
        guard sameKind.count > Self.replayLimit else { return }
        let stale = sameKind.first { !Self.isPlaying($0.value.payload) } ?? sameKind.first
        if let stale { latest[stale.key] = nil }
    }

    private static func isPlaying(_ payload: EventPayload) -> Bool {
        if case let .nowPlaying(value) = payload { value.state == .playing } else { false }
    }

    // MARK: Settings

    /// Where a setting is stored: `<id>.<key>`.
    func settingKey(_ key: String) -> String { "\(id.rawValue).\(key)" }

    /// Each declared setting's value: the stored one, or the manifest default.
    /// A toggle with neither is on. A stored toggle is read with
    /// `bool(forKey:)`, so a launch argument such as "NO" counts as off.
    private func readSettings() -> [String: SettingValue] {
        var values: [String: SettingValue] = [:]
        for spec in manifest.settings {
            let stored = settingKey(spec.key)
            switch spec.type {
            case .toggle:
                values[spec.key] = defaults.object(forKey: stored) == nil
                    ? spec.default ?? .bool(true)
                    : .bool(defaults.bool(forKey: stored))
            case .choice:
                if let value = defaults.string(forKey: stored) {
                    values[spec.key] = .string(value)
                } else if let value = spec.default {
                    values[spec.key] = value
                }
            case .note:
                break
            }
        }
        return values
    }

    /// Stores a setting the user changed and tells the running block.
    func setSetting(_ key: String, to value: SettingValue) {
        guard manifest.settings.contains(where: { $0.key == key }), settings[key] != value else { return }
        switch value {
        case let .bool(on): defaults.set(on, forKey: settingKey(key))
        case let .string(text): defaults.set(text, forKey: settingKey(key))
        }
        settings[key] = value
        if isWelcomed { send(.setting(key: key, value: value)) }
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
