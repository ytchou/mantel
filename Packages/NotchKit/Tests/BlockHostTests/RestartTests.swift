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

    @Test func restartReplaysEveryPlayer() async throws {
        let rig = Rig()
        try await rig.process.start()
        rig.runtime.publish(NowPlayingChanged(player: "Spotify", state: .playing, title: "Song"))
        rig.runtime.publish(NowPlayingChanged(player: "Chrome", state: .paused, title: "Video"))
        await waitUntil { rig.process.events.count == 2 }

        rig.process.close()
        await waitUntil { rig.launcher.processes.count == 2 }
        try await rig.process.start()
        await waitUntil { rig.process.events.count == 2 }

        // Spotify still plays: its event is replayed too, in arrival order.
        #expect(rig.process.events.map(\.payload) == [
            .nowPlaying(NowPlaying(player: "Spotify", state: .playing, title: "Song")),
            .nowPlaying(NowPlaying(player: "Chrome", state: .paused, title: "Video")),
        ])
        #expect(rig.process.events.allSatisfy { $0.replay })
    }

    @Test func replayIsBoundedAndKeepsPlayersThatPlay() async throws {
        let rig = Rig()
        try await rig.process.start()
        rig.runtime.publish(NowPlayingChanged(player: "Spotify", state: .playing, title: "Song"))
        let others = (1...RemoteBlock.replayLimit + 1).map { "Player \($0)" }
        for player in others {
            rig.runtime.publish(NowPlayingChanged(player: player, state: .paused))
        }
        await waitUntil { rig.process.events.count == others.count + 1 }

        rig.process.close()
        await waitUntil { rig.launcher.processes.count == 2 }
        try await rig.process.start()
        await waitUntil { rig.process.events.count == RemoteBlock.replayLimit }
        await settle()

        // The two oldest paused players are forgotten; the one that plays is kept.
        let players = rig.process.events.compactMap { event -> String? in
            if case let .nowPlaying(value) = event.payload { value.player } else { nil }
        }
        #expect(players == ["Spotify"] + others.dropFirst(2))
    }

    @Test func aSlowStartIsNotAHang() async throws {
        let rig = Rig()
        // No hello yet: ten seconds are allowed before the first welcome.
        await rig.beat(9)
        #expect(rig.launcher.processes.count == 1)
        #expect(rig.block.health == .ok)

        await rig.beat()
        await waitUntil { rig.launcher.processes.count == 2 }
        #expect(rig.block.health == .restarting(count: 1))

        // After welcome, the 3-second limit applies, counted from the welcome.
        try await rig.process.start()
        await rig.beat(2)
        #expect(rig.launcher.processes.count == 2)
        await rig.beat()
        await waitUntil { rig.launcher.processes.count == 3 }
        #expect(rig.launcher.processes.count == 3)
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

    /// The package is hashed again before a restart: a running block whose
    /// package changed on disk is not started again when its process dies.
    @Test func aChangedPackageIsNotRestartedAfterACrash() async throws {
        let setup = InstallTests.Setup()
        try setup.store.install(try setup.package())
        let first = try #require(setup.launcher.last)
        try await first.start()

        try InstallTests.Setup.changeOneByte(in: setup.blocksRoot.appending(path: "hello.topblock"))
        first.close()
        await waitUntil { setup.runtime.blocks.first is PendingBlock }

        let pending = try #require(setup.runtime.blocks.first as? PendingBlock)
        #expect(pending.review == .changed)
        #expect(setup.runtime.blocks.count == 1)
        await settle()
        #expect(setup.launcher.processes.count == 1, "not started again")
        #expect(!setup.store.canTurnOn("hello"))
        #expect(setup.store.canRemove("hello"))
    }

    /// An unchanged installed package still comes back after a crash.
    @Test func anUnchangedPackageIsRestartedAfterACrash() async throws {
        let setup = InstallTests.Setup()
        try setup.store.install(try setup.package())
        let first = try #require(setup.launcher.last)
        try await first.start()

        first.close()
        await waitUntil { setup.launcher.processes.count == 2 }

        #expect(setup.launcher.processes.count == 2)
        #expect(setup.block("hello")?.health == .restarting(count: 1))
    }

    @Test func stopDoesNotWaitForTheProcess() async throws {
        let block = try hungFixture()
        await waitLong { block.isWelcomed && block.processID != nil }
        let pid = try #require(block.processID)
        // Let the fixture take the welcome and block its main thread.
        try await Task.sleep(for: .milliseconds(200))

        let started = ContinuousClock.now
        block.stop()
        #expect(ContinuousClock.now - started < .milliseconds(300), "stop returns before the process exits")
        #expect(block.processID == nil)
        await waitLong { !processExists(pid) }
        #expect(!processExists(pid), "ended off the main thread")
    }

    @Test func stopAllWaitsOnceForEveryBlock() async throws {
        let blocks = try (0..<3).map { _ in try hungFixture() }
        await waitLong { blocks.allSatisfy { $0.isWelcomed && $0.processID != nil } }
        let pids = blocks.compactMap(\.processID)
        #expect(pids.count == 3)
        try await Task.sleep(for: .milliseconds(200))

        let started = ContinuousClock.now
        RemoteBlock.stopAll(blocks)
        let elapsed = ContinuousClock.now - started

        // Each hung fixture needs SIGTERM after 0.5 s; one after another that
        // would be 1.5 s or more.
        #expect(elapsed < .milliseconds(1200), "waited \(elapsed)")
        #expect(pids.allSatisfy { !processExists($0) })
        #expect(blocks.allSatisfy { $0.processID == nil })
    }

    /// A fixture block, registered in a runtime of its own, that blocks its
    /// main thread once welcomed: it exits only on a signal. Its heartbeat
    /// clock never moves, so no hang is seen.
    private func hungFixture() throws -> RemoteBlock {
        let package = try Fixture.package()
        let runtime = NotchRuntime()
        let defaults = testDefaults()
        defaults.set("hang", forKey: "fixture.command")
        let block = RemoteBlock(
            manifest: Fixture.manifest,
            packageURL: package,
            source: .development(path: package.path),
            dataFolder: FileManager.default.temporaryDirectory.appending(path: "topnotch-data-\(UUID().uuidString)"),
            owner: { runtime.state.owner },
            launcher: { try BlockProcess.spawn(executable: $0, generation: $1) },
            defaults: defaults,
            clock: BlockClock(ManualClock())
        )
        runtime.register(block)
        return block
    }

    /// Like `waitUntil`, for real processes: up to about five seconds.
    private func waitLong(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
