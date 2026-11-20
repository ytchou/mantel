import AppKit
import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

@MainActor
struct RemoteBlockTests {
    @Test func presentReachesRuntime() async throws {
        let rig = Rig()
        try await rig.process.start()

        try rig.process.send(present(priority: .interactive, seconds: 2.5))
        await waitUntil { rig.runtime.state.owner == "hello" }

        let presentation = try #require(rig.runtime.state.presentation)
        #expect(rig.runtime.state.owner == "hello")
        #expect(presentation.priority == .interactive)
        #expect(presentation.peek?.size == CGSize(width: 380, height: 52))
        #expect(presentation.duration == .milliseconds(2500))
        #expect(rig.block.model.peek == .text("Hi", style: .title))
    }

    @Test func updateDoesNotRePresent() async throws {
        let rig = Rig()
        try await rig.process.start()
        try rig.process.send(present())
        await waitUntil { rig.runtime.state.owner == "hello" }
        let shown = rig.runtime.state.presentation?.id

        let next = ViewNode.text("Changed", style: .secondary)
        try rig.process.send(.update(peek: next, wing: nil, expanded: nil))
        await waitUntil { rig.block.model.peek == next }

        #expect(rig.block.model.peek == next)
        #expect(rig.runtime.state.presentation?.id == shown)
    }

    @Test func updateWhileHiddenIsKept() async throws {
        let rig = Rig()
        try await rig.process.start()

        let hidden = ViewNode.text("Changed while hidden", style: .body)
        try rig.process.send(.update(peek: hidden, wing: nil, expanded: hidden))
        await waitUntil { rig.block.model.peek == hidden }
        // Stored, and nothing asked for the notch.
        #expect(rig.block.model.peek == hidden)
        #expect(rig.runtime.state.owner == nil)

        // The next present shows the model: its own peek, and the stored
        // expanded tree it did not resend.
        let shown = ViewNode.text("Shown", style: .title)
        try rig.process.send(present(shown))
        await waitUntil { rig.runtime.state.owner == "hello" }
        #expect(rig.block.model.peek == shown)
        #expect(rig.block.model.expanded == hidden)
        #expect(rig.runtime.state.presentation?.peek != nil)
    }

    @Test func dismissIfNotShownMatchesToday() async throws {
        let rig = Rig()
        let other = OtherBlock()
        rig.runtime.register(other)
        try await rig.process.start()

        // A higher-priority block holds the notch: the stand-in withdraws at once.
        // `interactive` counts only during an interaction, here a drag.
        rig.runtime.dragSessionChanged(active: true)
        rig.runtime.publish(DragSessionStarted(kinds: [.file]))
        other.show(.interactive)
        try rig.process.send(present(dismissIfNotShown: true))
        await settle()
        #expect(rig.runtime.state.owner == "other")
        other.context?.dismiss()
        #expect(rig.runtime.state.owner == nil, "the stand-in left nothing queued")

        // An equal-priority block holds it: the higher-ranked stand-in wins.
        other.show(.standard)
        try rig.process.send(present(dismissIfNotShown: true))
        await waitUntil { rig.runtime.state.owner == "hello" }
        #expect(rig.runtime.state.owner == "hello")
    }

    @Test func ownerIsPushed() async throws {
        let clock = ManualClock()
        let rig = Rig(clock: clock)
        try await rig.process.start()

        try rig.process.send(present(seconds: 3))
        let won = await rig.process.waitFor { $0 == .owner(owns: true) }
        #expect(won != nil)

        await waitUntil { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(3))
        let lost = await rig.process.waitFor { $0 == .owner(owns: false) }
        #expect(lost != nil)
        #expect(rig.runtime.state.owner == nil)
    }

    @Test func eventsBeforeWelcomeAreQueuedLiveThenReplayed() async throws {
        let rig = Rig()
        // Published after the launch, before the process said hello: live.
        rig.runtime.publish(OutputVolumeChanged(volume: 0.3, isMuted: false))
        rig.runtime.publish(NowPlayingChanged(player: "Spotify", state: .playing, title: "One"))
        rig.runtime.publish(OutputVolumeChanged(volume: 0.4, isMuted: false))
        try await rig.process.start()
        await waitUntil { rig.process.events.count == 3 }

        let first = rig.process.events
        #expect(first.map(\.payload) == [
            .outputVolume(OutputVolume(volume: 0.3, isMuted: false)),
            .nowPlaying(NowPlaying(player: "Spotify", state: .playing, title: "One")),
            .outputVolume(OutputVolume(volume: 0.4, isMuted: false)),
        ])
        #expect(first.allSatisfy { !$0.replay }, "a change during the start still shows a peek")
        // `welcome` comes first, with settings read from the manifest defaults.
        #expect(rig.process.received.first.map { message -> Bool in
            if case let .welcome(contract, settings, _) = message {
                contract == Contract.current && settings == ["loud": .bool(false), "size": .string("large")]
            } else { false }
        } == true)

        rig.runtime.publish(NowPlayingChanged(player: "Spotify", state: .playing, title: "Two"))
        await waitUntil { rig.process.events.count == 4 }
        #expect(rig.process.events.last?.replay == false)

        // A restarted process gets the latest event of each kind as a replay,
        // and a live event during its start as live.
        let firstProcess = rig.process
        rig.process.close()
        await waitUntil { rig.launcher.processes.count == 2 }
        #expect(rig.process.generation > firstProcess.generation)
        rig.runtime.publish(OutputVolumeChanged(volume: 0.6, isMuted: false))
        try await rig.process.start()
        await waitUntil { rig.process.events.count == 3 }
        #expect(rig.process.events.map(\.payload) == [
            .outputVolume(OutputVolume(volume: 0.4, isMuted: false)),
            .nowPlaying(NowPlaying(player: "Spotify", state: .playing, title: "Two")),
            .outputVolume(OutputVolume(volume: 0.6, isMuted: false)),
        ])
        #expect(rig.process.events.map(\.replay) == [true, true, false])
    }

    @Test func presentSecondsAreBounded() async throws {
        #expect(RemoteBlock.duration(seconds: .infinity) == nil)
        #expect(RemoteBlock.duration(seconds: .nan) == nil)
        #expect(RemoteBlock.duration(seconds: 0) == nil)
        #expect(RemoteBlock.duration(seconds: 2.5) == .milliseconds(2500))

        let rig = Rig()
        try await rig.process.start()
        // Before the fix this traps converting to `Duration`.
        try rig.process.send(present(seconds: 1e300))
        await waitUntil { rig.runtime.state.owner == "hello" }
        #expect(rig.runtime.state.presentation?.duration == .seconds(3600))

        try rig.process.send(present(.text("Again"), seconds: -1))
        await waitUntil { rig.block.model.peek == .text("Again") }
        await settle()
        #expect(rig.runtime.state.presentation?.duration == nil)
    }

    @Test func replacePackageWithdrawsWhatTheOldProcessShowed() async throws {
        let rig = Rig()
        try await rig.process.start()
        try rig.process.send(present())
        try rig.process.send(.actions(items: [ActionItem(id: "a", title: "A", enabled: true)]))
        await waitUntil { rig.runtime.state.owner == "hello" && !rig.block.actions.isEmpty }

        rig.block.replacePackage(manifest: helloManifest, source: rig.block.source)

        #expect(rig.runtime.state.owner == nil)
        #expect(rig.runtime.state.presentation == nil)
        #expect(rig.block.actions.isEmpty)
        #expect(rig.block.model.peek == nil)
        #expect(rig.launcher.processes.count == 2, "the new version starts at once")
    }

    @Test func stopWithdrawsWhatTheProcessShowed() async throws {
        let rig = Rig()
        try await rig.process.start()
        let first = rig.process
        try first.send(present())
        try first.send(.actions(items: [ActionItem(id: "a", title: "A", enabled: true)]))
        await waitUntil { rig.runtime.state.owner == "hello" && !rig.block.actions.isEmpty }

        rig.block.stop()

        #expect(rig.runtime.state.owner == nil)
        #expect(rig.block.actions.isEmpty)
        #expect(rig.block.model.peek == nil)
        #expect(await first.waitFor { $0 == .quit } != nil)
    }

    @Test func helloWithAnotherIDIsAFailure() async throws {
        let rig = Rig()
        var failures: [String] = []
        rig.block.onFailure = { failures.append($0) }

        try rig.process.send(.hello(contract: Contract.current, id: "someone-else", version: "1.0.0"))
        await waitUntil { !failures.isEmpty }
        await settle()

        let reason = try #require(failures.first)
        #expect(reason.contains("someone-else"))
        #expect(reason.contains("hello"))
        #expect(!rig.process.received.contains { if case .welcome = $0 { true } else { false } })
    }

    @Test func oldGenerationFramesAreDropped() async throws {
        let rig = Rig()
        try await rig.process.start()

        try rig.process.send(present(), generation: rig.process.generation - 1)
        try rig.process.send(.update(peek: .text("Old"), wing: nil, expanded: nil), generation: rig.process.generation - 1)
        await settle()

        #expect(rig.runtime.state.owner == nil)
        #expect(rig.block.model.peek == nil)
    }

    @Test func wrongContractInHelloIsAFailure() async throws {
        let rig = Rig()
        var failures: [String] = []
        rig.block.onFailure = { failures.append($0) }

        try rig.process.hello(contract: 99)
        try rig.process.send(present())
        await waitUntil { !failures.isEmpty }
        await settle()

        let reason = try #require(failures.first)
        #expect(reason.contains("99"))
        #expect(reason.contains("contracts 1 to 2"))
        #expect(rig.runtime.state.owner == nil)
        #expect(!rig.process.received.contains { if case .welcome = $0 { true } else { false } })
    }

    // MARK: Contract version 2

    @Test func presentWithAcceptsSetsPresentationAccepts() async throws {
        let rig = Rig()
        try await rig.process.start()

        try rig.process.send(present(accepts: [.file, .text]))
        await waitUntil { rig.runtime.state.owner == "hello" }

        let presentation = try #require(rig.runtime.state.presentation)
        #expect(presentation.accepts == [.file, .text])
    }

    @Test func eventsCarryIncreasingSeq() async throws {
        let rig = Rig()
        try await rig.process.start()

        rig.runtime.publish(OutputVolumeChanged(volume: 0.3, isMuted: false))
        rig.runtime.publish(OutputVolumeChanged(volume: 0.4, isMuted: false))
        rig.runtime.publish(NowPlayingChanged(player: "Spotify", state: .playing, title: "One"))
        await waitUntil { rig.process.eventSeqs.count == 3 }

        let seqs = rig.process.eventSeqs.compactMap { $0 }
        #expect(seqs.count == 3)
        #expect(zip(seqs, seqs.dropFirst()).allSatisfy { $1 == $0 + 1 })
    }

    @Test func lateAnswerWithDismissIfNotShownIsDropped() async throws {
        let rig = Rig()
        try await rig.process.start()
        rig.runtime.publish(OutputVolumeChanged(volume: 0.3, isMuted: false))
        await waitUntil { rig.process.eventSeqs.count == 1 }
        let seq = try #require(rig.process.eventSeqs.first ?? nil)

        // Over the answer window on the stand-in's clock, under the hang limit.
        await waitUntil { rig.heartbeat.sleeperCount > 0 }
        rig.heartbeat.advance(by: .milliseconds(2500))
        await settle()

        try rig.process.send(present(dismissIfNotShown: true, answering: seq))
        await settle()
        #expect(rig.runtime.state.owner == nil, "a late answer that asked to be dropped is not shown")
        #expect(rig.block.model.peek == nil)

        try rig.process.send(present(answering: seq))
        await waitUntil { rig.runtime.state.owner == "hello" }
        #expect(rig.runtime.state.owner == "hello", "without dismissIfNotShown a late answer is shown")
    }

    /// A real file in the temporary folder, which every block's sandbox reads.
    private func temporaryFile(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "topnotch-paths-\(UUID().uuidString)-\(name)")
        try Data("x".utf8).write(to: url)
        return url.path
    }

    @Test func previewAsksTheHostPreview() async throws {
        var shown: [[URL]] = []
        let rig = Rig(preview: { shown.append($0) })
        try await rig.process.start()
        let a = try temporaryFile("a.png")
        let b = try temporaryFile("b.pdf")

        try rig.process.send(.preview(paths: [a, b]))
        await waitUntil { !shown.isEmpty }

        #expect(shown == [[URL(fileURLWithPath: a), URL(fileURLWithPath: b)]])
    }

    /// Without `files.read`, a block may show only files its sandbox reads:
    /// a path elsewhere, such as a key in the home folder, is dropped.
    @Test func previewDropsPathsTheSandboxCannotRead() async throws {
        var shown: [[URL]] = []
        let rig = Rig(preview: { shown.append($0) })
        try await rig.process.start()
        let allowed = try temporaryFile("a.png")
        let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/id_rsa").path

        try rig.process.send(.preview(paths: ["/etc/hosts", home, "relative.png", allowed]))
        await waitUntil { !shown.isEmpty }
        #expect(shown == [[URL(fileURLWithPath: allowed)]])

        // Nothing readable: no preview at all.
        shown = []
        try rig.process.send(.preview(paths: ["/etc/hosts"]))
        await settle()
        #expect(shown.isEmpty)

        // With `files.read`, any absolute path.
        var reading = helloManifest
        reading.access = [.filesRead]
        var readingShown: [[URL]] = []
        let readingRig = Rig(manifest: reading, preview: { readingShown.append($0) })
        try await readingRig.process.start()
        try readingRig.process.send(.preview(paths: ["/etc/hosts", "relative.png"]))
        await waitUntil { !readingShown.isEmpty }
        #expect(readingShown == [[URL(fileURLWithPath: "/etc/hosts")]])
    }

    /// The same rule for the files of an item drag-out.
    @Test func dragOutLeavesOutFilesTheSandboxCannotRead() async throws {
        let rig = Rig()
        try await rig.process.start()
        let allowed = try temporaryFile("a.png")
        let drag = ViewNode.ItemDrag([.file(path: "/etc/hosts"), .file(path: allowed), .text(string: "hi")])

        let payloads = rig.block.model.dragPayloads(for: drag)
        #expect(payloads.count == 2)
        #expect((payloads.first?.writer as? NSURL)?.path == allowed)
        #expect(payloads.last?.writer is NSString)

        var reading = helloManifest
        reading.access = [.filesRead]
        let readingRig = Rig(manifest: reading)
        try await readingRig.process.start()
        #expect(readingRig.block.model.dragPayloads(for: drag).count == 3)
    }

    /// The sandbox opens the screenshot folder the process started with. When
    /// the folder changes, the next screenshot restarts the block first, and
    /// the new process gets the event live after its `welcome`.
    @Test func movedScreenshotFolderRestartsTheBlockBeforeTheEvent() async throws {
        final class Folder { var url = URL(fileURLWithPath: "/tmp/topnotch-shots-a") }
        let folder = Folder()
        var manifest = helloManifest
        manifest.events = ["screenshotCaptured"]
        manifest.access = [.filesScreenshots]
        let runtime = NotchRuntime()
        let launcher = FakeLauncher()
        let block = Rig.standIn(manifest: manifest, runtime: runtime, launcher: launcher, defaults: testDefaults(),
                                screenshotFolder: { folder.url })
        runtime.register(block)
        let first = try #require(launcher.last)
        try await first.start()

        runtime.publish(ScreenshotCaptured(url: folder.url.appending(path: "a.png"), createdAt: Date()))
        _ = await first.waitFor { if case .event = $0 { true } else { false } }
        #expect(launcher.processes.count == 1, "same folder: no restart")

        folder.url = URL(fileURLWithPath: "/tmp/topnotch-shots-b")
        let shot = folder.url.appending(path: "b.png")
        runtime.publish(ScreenshotCaptured(url: shot, createdAt: Date()))
        #expect(launcher.processes.count == 2)
        let second = try #require(launcher.last)
        try await second.start()
        _ = await second.waitFor { message in
            if case let .event(.screenshotCaptured(value), false, _) = message { value.path == shot.path } else { false }
        }
        let live = second.events.filter { !$0.replay }.map(\.payload)
        #expect(live.count == 1)
        if case let .screenshotCaptured(value) = live.first { #expect(value.path == shot.path) } else { Issue.record("no live screenshot") }
        #expect(block.health == .ok, "a restart for a new folder is not a failure")
    }
}
