import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

@MainActor
struct RestartTests {
    @Test func missedPongsAreAHang() async throws {
        let rig = Rig()
        try await rig.process.start()
        let first = rig.process

        // A ping each second; the block answers the first one.
        await rig.beat()
        _ = await first.waitFor { if case .ping = $0 { true } else { false } }
        try first.answerLatestPing()
        await waitUntil { rig.block.lastPong > 0 }

        // Real time passes with the clock still, as during sleep: no hang.
        try await Task.sleep(for: .milliseconds(50))
        // Two more seconds since the answer: still no hang.
        await rig.beat(2)
        #expect(rig.launcher.processes.count == 1)
        #expect(rig.block.health == .ok)

        // The third second with no answer is a hang: one failure, a new process.
        await rig.beat()
        await waitUntil { rig.launcher.processes.count == 2 }
        #expect(rig.launcher.processes.count == 2)
        #expect(rig.block.health == .restarting(count: 1))
        #expect(await first.waitFor { $0 == .quit } != nil, "the hung process was told to stop")
    }

    @Test func malformedFrameIsAFailure() async throws {
        let rig = Rig()
        try await rig.process.start()
        try rig.process.send(present())
        await waitUntil { rig.runtime.state.owner == "hello" }

        rig.process.sendGarbage()
        await waitUntil { rig.launcher.processes.count == 2 }

        #expect(rig.runtime.state.presentation == nil)
        #expect(rig.runtime.state.owner == nil)
        #expect(rig.block.health == .restarting(count: 1))
        #expect(rig.launcher.processes.count == 2)
    }

    @Test func restartReplaysState() async throws {
        let rig = Rig()
        try await rig.process.start()
        rig.runtime.publish(OutputVolumeChanged(volume: 0.5, isMuted: false))
        rig.runtime.publish(NowPlayingChanged(player: "Music", state: .playing, title: "Now"))
        await waitUntil { rig.process.events.count == 2 }

        rig.process.close()
        await waitUntil { rig.launcher.processes.count == 2 }
        try await rig.process.start()
        await waitUntil { rig.process.events.count == 2 }

        #expect(rig.process.events.map(\.payload) == [
            .outputVolume(OutputVolume(volume: 0.5, isMuted: false)),
            .nowPlaying(NowPlaying(player: "Music", state: .playing, title: "Now")),
        ])
        #expect(rig.process.events.allSatisfy { $0.replay })
        #expect(rig.block.health == .restarting(count: 1))
    }

    @Test func turnOffCallsInjectedClosureAndStoresReason() async throws {
        let rig = Rig()
        for count in 1...3 {
            try await rig.process.start()
            rig.process.close()
            if count < 3 { await waitUntil { rig.launcher.processes.count == count + 1 } }
        }
        await waitUntil { !rig.turnOffs.ids.isEmpty }
        await settle()

        #expect(rig.turnOffs.ids == ["hello"])
        #expect(rig.launcher.processes.count == 3, "no fourth process")
        let reason = try #require(rig.defaults.string(forKey: "block.hello.failure"))
        #expect(reason.hasPrefix("It stopped 3 times in a minute. Last reason: "))
        #expect(rig.block.health == .turnedOff(reason: reason))
        #expect(!rig.runtime.isEnabled("hello"))

        // After a relaunch, while it is off.
        let fresh = Rig.standIn(runtime: NotchRuntime(), launcher: FakeLauncher(), defaults: rig.defaults)
        #expect(fresh.health == .turnedOff(reason: reason))
    }

    @Test func turningOnClearsReason() async throws {
        let rig = Rig()
        for count in 1...3 {
            try await rig.process.start()
            rig.process.close()
            if count < 3 { await waitUntil { rig.launcher.processes.count == count + 1 } }
        }
        await waitUntil { !rig.turnOffs.ids.isEmpty }

        // The user turns it on.
        rig.runtime.setEnabled("hello", true)
        #expect(rig.defaults.object(forKey: "block.hello.failure") == nil)
        #expect(rig.block.health == .ok)
        #expect(rig.launcher.processes.count == 4)

        // The history is gone: one failure restarts, it does not turn off.
        try await rig.process.start()
        rig.process.close()
        await waitUntil { rig.launcher.processes.count == 5 }
        #expect(rig.block.health == .restarting(count: 1))
        #expect(rig.turnOffs.ids.count == 1)
    }

    @Test func killedFixtureComesBack() async throws {
        let package = try Fixture.package()
        let runtime = NotchRuntime()
        let other = OtherBlock()
        runtime.register(other)
        var turnedOff: [BlockID] = []
        let block = RemoteBlock(
            manifest: Fixture.manifest,
            packageURL: package,
            source: .development(path: package.path),
            dataFolder: FileManager.default.temporaryDirectory.appending(path: "topnotch-data-\(UUID().uuidString)"),
            owner: { runtime.state.owner },
            launcher: { try BlockProcess.spawn(executable: $0, generation: $1) },
            defaults: testDefaults(),
            turnOff: { turnedOff.append($0) }
        )
        runtime.register(block)
        defer { block.stop() }

        await waitLong { block.isWelcomed && block.processID != nil }
        let firstPID = try #require(block.processID)
        let firstGeneration = block.generation

        kill(firstPID, SIGKILL)
        await waitLong { block.isWelcomed && block.processID != nil && block.processID != firstPID }

        let secondPID = try #require(block.processID)
        #expect(secondPID != firstPID)
        #expect(block.generation > firstGeneration)
        #expect(block.health == .restarting(count: 1))
        #expect(turnedOff.isEmpty)
        // The runtime and the other block carry on.
        #expect(runtime.blocks.count == 2)
        other.show(.standard)
        #expect(runtime.state.owner == "other")
    }

    /// Like `waitUntil`, for real processes: up to about five seconds.
    private func waitLong(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
