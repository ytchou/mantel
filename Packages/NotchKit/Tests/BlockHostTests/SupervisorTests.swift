import Testing
@testable import BlockHost

/// The failure policy alone: times are given, nothing runs.
struct SupervisorTests {
    @Test func twoFailuresRestart() {
        var supervisor = Supervisor()
        #expect(supervisor.failed(at: .seconds(0)) == .restart)
        #expect(supervisor.failed(at: .seconds(59)) == .restart)
    }

    @Test func threeFailuresInWindowTurnOff() {
        var supervisor = Supervisor()
        _ = supervisor.failed(at: .seconds(10))
        _ = supervisor.failed(at: .seconds(30))
        #expect(supervisor.failed(at: .seconds(69)) == .turnOff)
    }

    @Test func oldFailuresFallOutOfWindow() {
        var supervisor = Supervisor()
        #expect(supervisor.failed(at: .seconds(0)) == .restart)
        #expect(supervisor.failed(at: .seconds(30.5)) == .restart)
        #expect(supervisor.failed(at: .seconds(61)) == .restart)
        // The one at 0 s is out; 30.5 s and 61 s remain, and one more turns off.
        #expect(supervisor.failed(at: .seconds(62)) == .turnOff)

        var reset = Supervisor()
        _ = reset.failed(at: .seconds(0))
        _ = reset.failed(at: .seconds(1))
        reset.reset()
        #expect(reset.failed(at: .seconds(2)) == .restart)
    }
}
