import BlockWire
import Foundation
import Synchronization
@testable import BlockHost
@testable import NotchCore
@testable import RenameBlock
@testable import ShelfBlock

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

struct NoTextReader: TextReading {
    func readText(at url: URL) async throws -> [RecognizedLine] {
        [RecognizedLine(text: "Payment Failed", box: CGRect(x: 0.1, y: 0.84, width: 0.5, height: 0.06))]
    }
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

struct GatedNamer: ScreenshotNaming {
    let status: ModelStatus = .available
    let gate: Gate
    func suggestName(_ request: NamingRequest) async throws -> String {
        await gate.wait()
        return "payment failed dialog"
    }
}

/// All blocks registered in one runtime, in the app's default order (Shelf,
/// Now Playing, Screenshot Names), with now-playing as a stand-in whose
/// process is `ScriptedNowPlaying`.
@MainActor
struct Fixture {
    let runtime: NotchRuntime
    let clock: ManualClock
    let shelf: ShelfBlock
    let rename: RenameBlock
    let nowPlaying: RemoteBlock
    let gate: Gate
    let folder: URL

    /// `gateOpen: false` holds naming until `gate.open()`.
    init(gateOpen: Bool = true) throws {
        folder = try makeFolder()
        clock = ManualClock()
        runtime = NotchRuntime(clock: clock)
        gate = Gate()
        if gateOpen { gate.open() }
        let suite = "BothBlocksTests-\(UUID().uuidString)"
        shelf = ShelfBlock(directory: try makeFolder(), defaults: UserDefaults(suiteName: suite)!)
        rename = RenameBlock(
            reader: NoTextReader(),
            namer: GatedNamer(gate: gate),
            defaults: UserDefaults(suiteName: suite)!,
            recentsURL: folder.appending(path: "state/recents.json")
        )
        runtime.register(shelf)
        let runtime = self.runtime
        nowPlaying = RemoteBlock(
            manifest: ScriptedNowPlaying.manifest,
            packageURL: URL(fileURLWithPath: "/tmp/NowPlaying.topblock"),
            source: .bundled,
            dataFolder: folder.appending(path: "data/nowplaying"),
            owner: { runtime.state.owner },
            launcher: { _, generation in
                let (app, block) = MemoryTransport.pair()
                ScriptedNowPlaying.run(on: block, generation: generation)
                return app
            },
            defaults: UserDefaults(suiteName: suite)!,
            // A clock of its own that never moves: no heartbeat, and the
            // runtime's clock holds only presentation timers.
            clock: BlockClock(ManualClock())
        )
        runtime.register(nowPlaying)
        runtime.register(rename)
    }

    /// Publishes an event the now-playing block listens to, and returns once
    /// the scripted block has answered it and the stand-in has handled the answer.
    func publishToNowPlaying<E: NotchEvent>(_ event: E) async {
        await waitUntil { nowPlaying.isWelcomed }
        let before = ScriptedNowPlaying.handledCount(in: nowPlaying)
        runtime.publish(event)
        await waitUntil { ScriptedNowPlaying.handledCount(in: nowPlaying) > before }
    }

    func capture(_ url: URL) {
        runtime.publish(ScreenshotCaptured(url: url, createdAt: Date()))
    }

    /// Where the shelf's file items point now.
    var shelfFileNames: [String] {
        shelf.store.stacks.flatMap(\.items).compactMap { shelf.store.fileURL(of: $0)?.lastPathComponent }
    }
}

/// Plays the now-playing block on the block's end of an in-memory
/// connection, as the real block behaves: a new song or a volume change
/// while a song plays presents the peek (standard priority, 3 s,
/// `dismissIfNotShown`); the last player stopping dismisses; replayed events
/// never present.
///
/// After each event it sends an `actions` frame whose one item id counts the
/// events handled. Frames are handled in order, so once the stand-in shows
/// that count, every frame the event caused has been handled too.
enum ScriptedNowPlaying {
    /// How long its peek stays; the real block's `TrackBlock.seconds`.
    static let duration: Duration = .seconds(3)

    /// The real block's manifest, read from `Blocks/NowPlaying/manifest.json`,
    /// so these tests follow it when it changes.
    static let manifest: Manifest = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BothBlocksTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NotchKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .appending(path: "Blocks/NowPlaying/manifest.json")
        do {
            return try Manifest.decode(Data(contentsOf: url))
        } catch {
            fatalError("Could not read the now-playing manifest at \(url.path): \(error)")
        }
    }()

    private static let handledPrefix = "handled-"

    /// The number of events the script has answered, as the stand-in last heard.
    @MainActor
    static func handledCount(in block: RemoteBlock) -> Int {
        block.actions.first.flatMap { Int($0.id.dropFirst(handledPrefix.count)) } ?? 0
    }

    static func run(on transport: MemoryTransport, generation: Int) {
        let stream = transport.envelopes(of: HostToBlock.self)
        Task {
            func send(_ message: BlockToHost) { try? transport.send(message, generation: generation) }
            send(.hello(contract: Contract.current, id: "nowplaying", version: "1.0.0"))
            var song: String?
            var handled = 0
            let peek = ViewSlot(width: 380, height: 52, root: .text("Song", style: .title))
            let show = BlockToHost.present(priority: .standard, peek: peek, wing: nil, expanded: nil, opensAt: .peek,
                                           seconds: duration / .seconds(1), dismissIfNotShown: true)
            do {
                for try await envelope in stream {
                    switch envelope.message {
                    case let .ping(seq):
                        send(.pong(seq: seq))
                    case .quit:
                        return
                    case let .event(.nowPlaying(change), replay, _):
                        if change.state == .playing {
                            let current = "\(change.player)/\(change.title)/\(change.artist)"
                            if current != song {
                                song = current
                                if !replay { send(show) }
                            }
                        } else {
                            song = nil
                            send(.dismiss)
                        }
                        handled += 1
                        send(.actions(items: [ActionItem(id: "\(handledPrefix)\(handled)", title: "Handled", enabled: false)]))
                    case let .event(.outputVolume, replay, _):
                        if song != nil, !replay { send(show) }
                        handled += 1
                        send(.actions(items: [ActionItem(id: "\(handledPrefix)\(handled)", title: "Handled", enabled: false)]))
                    default:
                        break
                    }
                }
            } catch {
                // The app closed the connection: the block is gone.
            }
        }
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
