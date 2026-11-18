import SwiftUI
import Synchronization
@testable import NotchCore

struct Ping: NotchEvent { let n: Int }
struct Pong: NotchEvent {}

@MainActor
final class FakeBlock: NotchBlock {
    let id: BlockID
    let title = "Fake"
    private(set) var context: (any BlockContext)?
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var inputs: [NotchInput] = []
    var onActivate: (@MainActor (any BlockContext) -> Void)?
    var onDeactivate: (@MainActor () -> Void)?

    init(_ id: BlockID) { self.id = id }

    func activate(_ context: any BlockContext) {
        self.context = context
        activations += 1
        onActivate?(context)
    }

    func deactivate() {
        deactivations += 1
        onDeactivate?()
    }

    func handle(_ input: NotchInput) { inputs.append(input) }
}

@MainActor
func content() -> NotchContent {
    NotchContent(size: CGSize(width: 10, height: 10)) { EmptyView() }
}

@MainActor
func peekPresentation(
    _ priority: PresentationPriority = .standard,
    duration: Duration? = nil,
    accepts: Set<DropKind> = []
) -> Presentation {
    Presentation(priority: priority, peek: content(), duration: duration, accepts: accepts)
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

/// Let the runtime's timer task run, until `condition` holds or about a second passes.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
