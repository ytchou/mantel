/// Decides what happens when a block process fails: start it again, or turn
/// the block off after too many failures in a short time.
///
/// Pure policy. It holds failure times and nothing else; the caller passes the
/// time of each failure, read from a clock that stops while the Mac sleeps.
struct Supervisor: Sendable, Equatable {
    enum Decision: Sendable, Equatable {
        case restart
        case turnOff
    }

    /// Failures within this span count together.
    static let window: Duration = .seconds(60)
    /// This many failures within `window` turn the block off.
    static let limit = 3

    /// Times of the failures still inside the window, oldest first.
    private(set) var failures: [Duration] = []

    /// Records a failure at `now` and decides.
    mutating func failed(at now: Duration) -> Decision {
        failures.append(now)
        failures.removeAll { now - $0 >= Self.window }
        return failures.count >= Self.limit ? .turnOff : .restart
    }

    /// Forgets every failure, as when the user turns the block on again.
    mutating func reset() {
        failures = []
    }
}
