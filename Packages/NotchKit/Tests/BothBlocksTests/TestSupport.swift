import BlockWire
import Foundation
import Synchronization
@testable import BlockHost
@testable import NotchCore

/// A new empty folder under the system temporary folder.
func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "BothBlocksTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.standardizedFileURL
}

@discardableResult
func makeScreenshot(_ name: String, in folder: URL) throws -> URL {
    let url = folder.appending(path: name, directoryHint: .notDirectory)
    try Data("image".utf8).write(to: url)
    return url
}

/// Holds every naming request until `open()` is called, then answers at once.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.isOpen { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// All three blocks registered in one runtime, in the app's default order
/// (Shelf, Now Playing, Screenshot Names). Each is a stand-in, as in the app,
/// whose process is a script over an in-memory connection: `ScriptedShelf`,
/// `ScriptedNowPlaying` and `ScriptedRename`.
///
/// A block answers in its own time, so every call that reaches a block
/// (`publish`, `drop`, `hover`, `setEnabled`) returns only once the blocks
/// that heard it answered and the stand-ins handled the answer.
@MainActor
struct Fixture {
    let runtime: NotchRuntime
    let clock: ManualClock
    let shelf: ScriptedShelf
    let nowPlaying: ScriptedNowPlaying
    let rename: ScriptedRename
    let gate: Gate
    /// Where the screenshots are taken.
    let folder: URL
    /// The stand-ins, in registration order, by id.
    let standIns: [BlockID: RemoteBlock]

    private var scripts: [ScriptedBlock] { [shelf, nowPlaying, rename] }

    /// `gateOpen: false` holds naming until `gate.open()`.
    init(gateOpen: Bool = true) throws {
        folder = try makeFolder()
        let data = try makeFolder()
        clock = ManualClock()
        runtime = NotchRuntime(clock: clock)
        gate = Gate()
        if gateOpen { gate.open() }
        shelf = ScriptedShelf()
        nowPlaying = ScriptedNowPlaying()
        rename = ScriptedRename(gate: gate)
        let suite = "BothBlocksTests-\(UUID().uuidString)"
        let runtime = self.runtime
        var standIns: [BlockID: RemoteBlock] = [:]
        for script in [shelf, nowPlaying, rename] as [ScriptedBlock] {
            let block = RemoteBlock(
                manifest: script.manifest,
                packageURL: URL(fileURLWithPath: "/tmp/\(script.manifest.executable).topblock"),
                source: .bundled,
                dataFolder: data.appending(path: script.manifest.id),
                owner: { runtime.state.owner },
                launcher: { _, generation in script.launch(generation: generation) },
                defaults: UserDefaults(suiteName: suite)!,
                // A clock of its own that never moves: no heartbeat, and the
                // runtime's clock holds only presentation timers.
                clock: BlockClock(ManualClock())
            )
            runtime.register(block)
            standIns[block.id] = block
        }
        self.standIns = standIns
    }

    /// Publishes an event, and returns once every enabled block that listens
    /// to it has taken it and everything it caused is handled.
    func publish<E: NotchEvent>(_ event: E) async {
        await reach(EventCodec.payload(for: event)?.name) { runtime.publish(event) }
    }

    func capture(_ url: URL) async {
        await publish(ScreenshotCaptured(url: url, createdAt: Date()))
    }

    /// The pointer enters or leaves the notch; the shelf hears it.
    func hover(_ isInside: Bool) async {
        await reach(.pointerHover) { runtime.pointerHoverChanged(isInside: isInside) }
    }

    /// Items dropped on the notch; the owner takes those its presentation accepts.
    func drop(_ items: [DroppedItem]) async {
        let owner = runtime.state.owner.flatMap { id in scripts.first { $0.manifest.id == id.rawValue } }
        let before = owner?.taken ?? 0
        runtime.send(.drop(items))
        if let owner { await waitUntil { owner.taken > before } }
        await settle()
    }

    /// Turns a block on or off; off returns once its process has ended.
    func setEnabled(_ id: BlockID, _ enabled: Bool) async {
        runtime.setEnabled(id, enabled)
        if !enabled, let script = scripts.first(where: { $0.manifest.id == id.rawValue }) {
            await waitUntil { !script.isRunning(script.generation) }
        }
        await settle()
    }

    /// Runs `body`, then waits until each enabled block listening to `event`
    /// took one more message, and everything settled.
    private func reach(_ event: WireEvent?, _ body: () -> Void) async {
        let listeners = scripts.filter { script in
            guard let event else { return false }
            return runtime.isEnabled(BlockID(rawValue: script.manifest.id)) && script.manifest.events.contains(event.rawValue)
        }
        let before = listeners.map(\.taken)
        body()
        await waitUntil { zip(listeners, before).allSatisfy { pair in pair.0.taken > pair.1 } }
        await settle()
    }

    /// Waits until each enabled stand-in is welcomed and has handled every
    /// frame its script sent so far.
    func settle() async {
        await waitUntil {
            scripts.allSatisfy { script in
                let id = BlockID(rawValue: script.manifest.id)
                guard runtime.isEnabled(id), let block = standIns[id] else { return true }
                return block.isWelcomed && ScriptedBlock.step(shownBy: block) == script.step
            }
        }
    }

    /// Waits until `condition` holds, then until everything settled.
    func waitFor(_ condition: () -> Bool) async {
        await waitUntil(condition)
        await settle()
    }

    /// The names of the files in the screenshot folder, sorted.
    var screenshotNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}

// MARK: - Scripted blocks

/// Plays a block on the block's end of an in-memory connection: says hello,
/// answers pings and hands every other message to the subclass.
///
/// After each message it handles, and after each change it makes on its own,
/// it sends an `actions` frame whose one item id is its `step`. Frames are
/// handled in order, so once the stand-in shows that step, every frame the
/// script sent before is handled too.
@MainActor
class ScriptedBlock {
    let manifest: Manifest
    /// The number of changes made, as last sent in `actions`.
    private(set) var step = 0
    /// The events and inputs taken, over every process.
    private(set) var taken = 0
    /// Whether the app last said this block owns the notch.
    private(set) var owns = false
    /// The generation of the running process; its transport is nil once it ended.
    private(set) var generation = 0
    private var transport: MemoryTransport?

    private static let stepPrefix = "step-"

    /// - Parameter folder: the block's folder under `Blocks/`, whose
    ///   `manifest.json` is read, so these tests follow it when it changes.
    init(folder: String) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BothBlocksTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NotchKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .appending(path: "Blocks/\(folder)/manifest.json")
        do {
            manifest = try Manifest.decode(Data(contentsOf: url))
        } catch {
            fatalError("Could not read the manifest at \(url.path): \(error)")
        }
    }

    /// The step the stand-in last heard from its script.
    static func step(shownBy block: RemoteBlock) -> Int {
        block.actions.first.flatMap { Int($0.id.dropFirst(stepPrefix.count)) } ?? 0
    }

    /// The launcher: a new process, with the state kept across processes.
    func launch(generation: Int) -> any Transport {
        let (app, block) = MemoryTransport.pair()
        self.generation = generation
        transport = block
        owns = false
        let stream = block.envelopes(of: HostToBlock.self)
        Task {
            send(.hello(contract: Contract.current, id: manifest.id, version: manifest.version))
            do {
                for try await envelope in stream {
                    guard self.isRunning(generation) else { return }
                    switch envelope.message {
                    case let .ping(seq):
                        send(.pong(seq: seq))
                        continue
                    case .quit:
                        end(generation)
                        return
                    case .welcome:
                        started()
                    case let .owner(owns):
                        self.owns = owns
                        ownerChanged(owns)
                    case let .event(payload, replay, _):
                        taken += 1
                        // A replay is from before this process; the blocks ignore those.
                        if !replay { event(payload) }
                    case let .input(input):
                        taken += 1
                        self.input(input)
                    default:
                        break
                    }
                    changed()
                }
            } catch {
                // The app closed the connection.
            }
            end(generation)
        }
        return app
    }

    /// True while the process of `generation` runs.
    func isRunning(_ generation: Int) -> Bool {
        transport != nil && generation == self.generation
    }

    func send(_ message: BlockToHost) {
        try? transport?.send(message, generation: generation)
    }

    /// Sends the next step. Call after a change made outside a message.
    func changed() {
        step += 1
        send(.actions(items: [ActionItem(id: "\(Self.stepPrefix)\(step)", title: "Step", enabled: false)]))
    }

    private func end(_ generation: Int) {
        guard isRunning(generation) else { return }
        transport = nil
        stopped()
    }

    func present(_ priority: Priority, peek: ViewSlot? = nil, wing: ViewSlot? = nil, expanded: ViewSlot? = nil,
                 opensAt: Level = .peek, seconds: Double? = nil, dismissIfNotShown: Bool = false,
                 accepts: [DragStarted.Kind]? = nil) {
        send(.present(priority: priority, peek: peek, wing: wing, expanded: expanded, opensAt: opensAt,
                      seconds: seconds, dismissIfNotShown: dismissIfNotShown, accepts: accepts))
    }

    // What the subclass plays.
    func started() {}
    func stopped() {}
    func ownerChanged(_ owns: Bool) {}
    func event(_ payload: EventPayload) {}
    func input(_ input: WireInput) {}
}

/// Plays the shelf block (`Blocks/Shelf`) as far as these tests need: a drag
/// presents the drop target (interactive, expanded, taking drops); held items
/// rest as an ambient wing; the pointer on the shelf it shows makes it
/// interactive until the pointer leaves; dropped items and new screenshots
/// are held. Items are kept across processes, as the real block stores them.
/// Not played: the late-drop grace and drag-out.
final class ScriptedShelf: ScriptedBlock {
    enum Mode { case none, dropTarget, browsing, ambient }

    private(set) var items: [String] = []
    var itemCount: Int { items.count }

    private var mode = Mode.none
    private var pointerInside = false
    private var isBrowsing = false
    private var isDragActive = false

    private static let accepted: [DragStarted.Kind] = [.file, .link, .text]
    private static let expanded = ViewSlot(width: 520, height: 180, root: .text("Shelf", style: .title))
    private static let wing = ViewSlot(width: 40, height: 32, root: .text("Items", style: .secondary))

    init() { super.init(folder: "Shelf") }

    override func started() {
        mode = .none
        pointerInside = false
        isBrowsing = false
        isDragActive = false
        refresh()
    }

    override func ownerChanged(_ owns: Bool) {
        guard owns, pointerInside, !isBrowsing else { return }
        isBrowsing = true
        refresh()
    }

    override func event(_ payload: EventPayload) {
        switch payload {
        case .dragStarted:
            isDragActive = true
        case .dragEnded:
            isDragActive = false
        case let .pointerHover(hover):
            pointerInside = hover.isInside
            // In use only when the pointer landed on the shelf, not on another block.
            isBrowsing = hover.isInside && owns
        case let .screenshotCaptured(shot):
            items.append(shot.path)
        default:
            return
        }
        refresh()
    }

    override func input(_ input: WireInput) {
        guard case let .drop(dropped) = input else { return }
        items += dropped.map { "\($0)" }
        refresh()
    }

    private func refresh() {
        let next: Mode = isDragActive ? .dropTarget : items.isEmpty ? .none : isBrowsing ? .browsing : .ambient
        guard next != mode else { return }
        mode = next
        switch next {
        case .none:
            send(.dismiss)
        case .dropTarget:
            present(.interactive, expanded: Self.expanded, opensAt: .expanded, accepts: Self.accepted)
        case .browsing:
            present(.interactive, wing: Self.wing, expanded: Self.expanded, accepts: Self.accepted)
        case .ambient:
            present(.ambient, wing: Self.wing, expanded: Self.expanded, accepts: Self.accepted)
        }
    }
}

/// Plays the rename block (`Blocks/Rename`): each new screenshot is queued;
/// the one being named shows in the peek (standard priority, until
/// dismissed); once `gate` opens it is renamed in place to
/// `payment-failed-dialog.png` (a number added when taken), and after the
/// last one the result shows for `resultDuration`. Turned off mid-job, the
/// file keeps its name. The recent renames are kept across processes.
final class ScriptedRename: ScriptedBlock {
    /// The real block's `RenameBlock.resultDuration`.
    static let resultDuration: Duration = .seconds(6)

    enum Phase: Equatable { case idle, naming, renamed(String) }

    let gate: Gate
    private(set) var phase = Phase.idle
    /// New names, newest first.
    private(set) var recents: [String] = []
    /// Screenshots queued behind the one being named.
    private(set) var waiting = 0
    private var queue: [URL] = []
    private var current: URL?

    private static let peek = ViewSlot(width: 380, height: 52, root: .text("Naming", style: .title))

    init(gate: Gate) {
        self.gate = gate
        super.init(folder: "Rename")
    }

    override func stopped() {
        queue = []
        current = nil
        waiting = 0
        phase = .idle
    }

    override func event(_ payload: EventPayload) {
        guard case let .screenshotCaptured(shot) = payload else { return }
        let url = URL(fileURLWithPath: shot.path).standardizedFileURL
        guard current != url, !queue.contains(url) else { return }
        queue.append(url)
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        waiting = queue.count
        guard current == nil, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        current = url
        waiting = queue.count
        phase = .naming
        present(.standard, peek: Self.peek)
        let generation = self.generation
        Task {
            await gate.wait()
            guard isRunning(generation), current == url else { return }
            finish(url)
            changed()
        }
    }

    private func finish(_ url: URL) {
        current = nil
        let folder = url.deletingLastPathComponent()
        var name = "payment-failed-dialog.\(url.pathExtension)"
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
            name = "payment-failed-dialog-\(number).\(url.pathExtension)"
            number += 1
        }
        if (try? FileManager.default.moveItem(at: url, to: folder.appending(path: name))) != nil {
            recents.insert(name, at: 0)
            if queue.isEmpty {
                phase = .renamed(name)
                present(.standard, peek: Self.peek, seconds: Self.resultDuration / .seconds(1))
            }
        } else if queue.isEmpty {
            phase = .idle
            send(.dismiss)
        }
        startNextIfIdle()
    }
}

/// Plays the now-playing block (`Blocks/NowPlaying`): a new song or a volume
/// change while a song plays presents the peek (standard priority, 3 s,
/// `dismissIfNotShown`); the last player stopping dismisses; replayed events
/// never present.
final class ScriptedNowPlaying: ScriptedBlock {
    /// How long its peek stays; the real block's `TrackBlock.seconds`.
    static let duration: Duration = .seconds(3)

    private var song: String?

    private static let peek = ViewSlot(width: 380, height: 52, root: .text("Song", style: .title))

    init() { super.init(folder: "NowPlaying") }

    override func stopped() { song = nil }

    override func event(_ payload: EventPayload) {
        switch payload {
        case let .nowPlaying(change):
            if change.state == .playing {
                let current = "\(change.player)/\(change.title)/\(change.artist)"
                guard current != song else { return }
                song = current
                show()
            } else {
                song = nil
                send(.dismiss)
            }
        case .outputVolume:
            if song != nil { show() }
        default:
            break
        }
    }

    private func show() {
        present(.standard, peek: Self.peek, seconds: Self.duration / .seconds(1), dismissIfNotShown: true)
    }
}

/// Let tasks run until `condition` holds or about five seconds pass.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A clock that moves only when told to.
final class ManualClock: Clock, Sendable {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        typealias Duration = Swift.Duration
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private enum Outcome { case wait, ready, cancelled }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    /// Tasks asleep on this clock right now.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { s -> Outcome in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= s.now { return .ready }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .ready: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = s.now.advanced(by: duration)
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }
            s.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
