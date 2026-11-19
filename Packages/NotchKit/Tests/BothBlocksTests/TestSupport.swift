import Foundation
import Synchronization
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

/// Both blocks registered in one runtime, as the app does: shelf first.
@MainActor
struct Fixture {
    let runtime: NotchRuntime
    let clock: ManualClock
    let shelf: ShelfBlock
    let rename: RenameBlock
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
        runtime.register(rename)
    }

    func capture(_ url: URL) {
        runtime.publish(ScreenshotCaptured(url: url, createdAt: Date()))
    }

    /// Where the shelf's file items point now.
    var shelfFileNames: [String] {
        shelf.store.stacks.flatMap(\.items).compactMap { shelf.store.fileURL(of: $0)?.lastPathComponent }
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
