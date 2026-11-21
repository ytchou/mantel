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

/// A block the resource watch stops is turned off at once, through the
/// same path as repeated failures, without the failure count.
@MainActor
struct RunawayTests {
    @Test func aStoppedRunawayIsTurnedOffNotRestarted() async throws {
        let samples = FakeSamples()
        let rig = Rig(samples: samples)
        try await rig.process.start()

        // One ordinary failure: restarted, counted by the supervisor.
        rig.process.close()
        await waitUntil { rig.launcher.processes.count == 2 }
        try await rig.process.start()

        samples.setMemory(600 * 1024 * 1024)
        await rig.sample(samples)
        await waitUntil { !rig.turnOffs.ids.isEmpty }
        await settle()

        let reason = "It was stopped because it used more than 500 MB of memory."
        #expect(rig.turnOffs.ids == ["hello"])
        #expect(rig.block.health == .turnedOff(reason: reason))
        #expect(rig.defaults.string(forKey: RemoteBlock.failureKey("hello")) == reason)
        // Not restarted, and not the "stopped 3 times" sentence.
        #expect(rig.launcher.processes.count == 2)
        #expect(rig.block.usage == nil)
        #expect(rig.resourceClock.sleeperCount == 0)
    }
}
