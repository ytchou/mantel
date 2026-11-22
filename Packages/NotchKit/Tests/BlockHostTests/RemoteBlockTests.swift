import AppKit
import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

@MainActor
struct RemoteBlockTests {
    /// B5: a block whose start check refuses raises no demand, so no event
    /// source starts and no permission is asked for it.
    @Test func aRefusedStartSubscribesToNothing() async throws {
        let runtime = NotchRuntime()
        let launcher = FakeLauncher()
        let block = Rig.standIn(runtime: runtime, launcher: launcher, defaults: testDefaults())
        block.startCheck = { "Changed: its package changed after you approved it." }

        runtime.register(block)

        #expect(!runtime.hasSubscribers(for: PointerHoverChanged.self))
        #expect(launcher.processes.isEmpty)

        // Control: once the check passes, turning it on subscribes and starts it.
        block.startCheck = { nil }
        runtime.setEnabled(block.id, false)
        runtime.setEnabled(block.id, true)
        #expect(runtime.hasSubscribers(for: PointerHoverChanged.self))
        #expect(launcher.processes.count == 1)
    }

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
            if case let .welcome(contract, settings, _, _) = message {
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
        #expect(RemoteBlock.duration(seconds: .infinity, priority: .ambient) == nil)
        #expect(RemoteBlock.duration(seconds: .nan, priority: .ambient) == nil)
        #expect(RemoteBlock.duration(seconds: 0, priority: .ambient) == nil)
        #expect(RemoteBlock.duration(seconds: 2.5, priority: .ambient) == .milliseconds(2500))
        #expect(RemoteBlock.duration(seconds: 2.5, priority: .standard) == .milliseconds(2500))

        let rig = Rig()
        try await rig.process.start()
        // Before the fix this traps converting to `Duration`.
        try rig.process.send(present(priority: .ambient, seconds: 1e300))
        await waitUntil { rig.runtime.state.owner == "hello" }
        #expect(rig.runtime.state.presentation?.duration == .seconds(3600))

        try rig.process.send(present(.text("Again"), priority: .ambient, seconds: -1))
        await waitUntil { rig.block.model.peek == .text("Again") }
        await settle()
        #expect(rig.runtime.state.presentation?.duration == nil)
    }

    @Test func aStandardPresentationIsCappedAtSixtySeconds() async throws {
        #expect(RemoteBlock.standardMaxSeconds == 60)
        #expect(RemoteBlock.duration(seconds: 1e300, priority: .standard) == .seconds(60))

        let rig = Rig()
        try await rig.process.start()
        try rig.process.send(present(priority: .standard, seconds: 3600))
        await waitUntil { rig.runtime.state.owner == "hello" }
        #expect(rig.runtime.state.presentation?.duration == .seconds(60))
    }

    @Test func aStandardPresentationWithNoEndGetsSixtySeconds() async throws {
        for seconds: Double in [0, -1, .infinity, .nan] {
            #expect(RemoteBlock.duration(seconds: seconds, priority: .standard) == .seconds(60), "\(seconds)")
        }

        let rig = Rig()
        try await rig.process.start()
        try rig.process.send(present(priority: .standard, seconds: nil))
        await waitUntil { rig.runtime.state.owner == "hello" }
        #expect(rig.runtime.state.presentation?.duration == .seconds(60))
    }

    @Test func ambientAndInteractiveKeepNoEnd() async throws {
        let rig = Rig()
        try await rig.process.start()
        try rig.process.send(present(.text("Low"), priority: .ambient, seconds: nil))
        await waitUntil { rig.block.model.peek == .text("Low") && rig.runtime.state.owner == "hello" }
        #expect(rig.runtime.state.presentation?.priority == .ambient)
        #expect(rig.runtime.state.presentation?.duration == nil)

        try rig.process.send(present(.text("Top"), priority: .interactive, seconds: nil))
        await waitUntil { rig.block.model.peek == .text("Top") && rig.runtime.state.presentation?.priority == .interactive }
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
        #expect(reason.contains("contracts 1 to 3"))
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

    /// A real file in the block's own temporary folder, which its sandbox reads.
    private func temporaryFile(_ name: String, in rig: Rig) throws -> String {
        let url = rig.block.temporaryFolder.appending(path: "mantel-paths-\(UUID().uuidString)-\(name)")
        try Data("x".utf8).write(to: url)
        return url.path
    }

    /// The app's `Mantel` temporary subtree holds other blocks' files and
    /// the drop folder: closed. The block's own temporary folder inside it is
    /// open. The rest of the shared temporary folder is not readable to the
    /// sandbox, so it is not shown either.
    @Test func readablePathsTakeTheBlocksOwnTemporaryFolderNotOtherBlocks() throws {
        let rig = Rig()
        let own = try temporaryFile("own.png", in: rig)
        let otherBlock = rig.sharedTemporaryFolder.appending(path: "Mantel/Blocks/other")
        try FileManager.default.createDirectory(at: otherBlock, withIntermediateDirectories: true)
        let shared = otherBlock.appending(path: "other-block.png")
        try Data("x".utf8).write(to: shared)
        let otherApp = rig.sharedTemporaryFolder.appending(path: "other-app.png")
        try Data("x".utf8).write(to: otherApp)
        let dropped = rig.dropFolder.appending(path: "UUID-1/drop.png")
        try FileManager.default.createDirectory(at: dropped.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dropped)

        #expect(rig.block.temporaryFolder.path.hasPrefix(rig.sharedTemporaryFolder.appending(path: "Mantel/Blocks/hello").path))
        #expect(rig.block.readablePaths([shared.path, dropped.path, own, otherApp.path]) == [own])

        // `files.read` opens the home folder, not the app's temporary subtree.
        var reading = helloManifest
        reading.access = [.filesRead]
        let readingRig = Rig(manifest: reading)
        let readingShared = readingRig.sharedTemporaryFolder.appending(path: "Mantel/Drops/UUID-1/drop.png")
        let readingOwn = try temporaryFile("own.png", in: readingRig)
        #expect(readingRig.block.readablePaths([readingShared.path, "/etc/hosts", readingOwn]) == ["/etc/hosts", readingOwn])
    }

    @Test func previewAsksTheHostPreview() async throws {
        var shown: [[URL]] = []
        let rig = Rig(preview: { shown.append($0) })
        try await rig.process.start()
        let a = try temporaryFile("a.png", in: rig)
        let b = try temporaryFile("b.pdf", in: rig)

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
        let allowed = try temporaryFile("a.png", in: rig)
        let home = homeFile

        try rig.process.send(.preview(paths: [home, "relative.png", allowed]))
        await waitUntil { !shown.isEmpty }
        #expect(shown == [[URL(fileURLWithPath: allowed)]])

        // Nothing readable: no preview at all.
        shown = []
        try rig.process.send(.preview(paths: [home]))
        await settle()
        #expect(shown.isEmpty)

        // With `files.read`, a file in the home folder.
        var reading = helloManifest
        reading.access = [.filesRead]
        var readingShown: [[URL]] = []
        let readingRig = Rig(manifest: reading, preview: { readingShown.append($0) })
        try await readingRig.process.start()
        try readingRig.process.send(.preview(paths: [home, "relative.png"]))
        await waitUntil { !readingShown.isEmpty }
        #expect(readingShown == [[URL(fileURLWithPath: home)]])
    }

    /// A file in the home folder, outside every rig's folders. It need not exist.
    private var homeFile: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/mantel-test-\(UUID().uuidString).txt").path
    }

    /// A2: `files.read` never shows Mantel's support folder (the approvals,
    /// other blocks' data), and no block shows the shared temporary folder.
    @Test func previewAndDragOutFollowTheSandboxRule() async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "mantel-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let approvals = support.appending(path: "Approvals.json")
        let otherData = support.appending(path: "BlockData/other/secret.txt")
        try FileManager.default.createDirectory(at: otherData.deletingLastPathComponent(), withIntermediateDirectories: true)
        for file in [approvals, otherData] { try Data("x".utf8).write(to: file) }

        var reading = helloManifest
        reading.access = [.filesRead]
        let runtime = NotchRuntime()
        let launcher = FakeLauncher()
        let block = RemoteBlock(
            manifest: reading, packageURL: URL(fileURLWithPath: "/tmp/Hello.mantelblock"),
            source: .development(path: "/tmp/Hello.mantelblock"),
            dataFolder: support.appending(path: "BlockData/hello"), owner: { runtime.state.owner },
            launcher: launcher.launcher, defaults: testDefaults(),
            sharedTemporaryFolder: Rig.newSharedTemporaryFolder(), supportRoot: support
        )
        // The support folder sits inside the "home" folder, as in the app.
        block.homeFolder = support.deletingLastPathComponent()
        let note = support.deletingLastPathComponent().appending(path: "mantel-note-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: note) }
        try Data("x".utf8).write(to: note)

        #expect(block.readablePaths([approvals.path, otherData.path, note.path]) == [note.path])
        let drag = ViewNode.ItemDrag([.file(path: approvals.path), .file(path: otherData.path)])
        #expect(block.model.dragPayloads(for: drag).isEmpty)

        // No tokens: a file in the shared temporary folder is not shown.
        let rig = Rig()
        let shared = rig.sharedTemporaryFolder.appending(path: "other-app.png")
        try FileManager.default.createDirectory(at: rig.sharedTemporaryFolder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: shared)
        #expect(rig.block.readablePaths([shared.path]).isEmpty)
    }

    /// The same rule for the files of an item drag-out.
    @Test func dragOutLeavesOutFilesTheSandboxCannotRead() async throws {
        let rig = Rig()
        try await rig.process.start()
        let allowed = try temporaryFile("a.png", in: rig)
        let drag = ViewNode.ItemDrag([.file(path: homeFile), .file(path: allowed), .text(string: "hi")])

        let payloads = rig.block.model.dragPayloads(for: drag)
        #expect(payloads.count == 2)
        #expect((payloads.first?.writer as? NSURL)?.path == allowed)
        #expect(payloads.last?.writer is NSString)

        var reading = helloManifest
        reading.access = [.filesRead]
        let readingRig = Rig(manifest: reading)
        try await readingRig.process.start()
        // `files.read` adds the home folder; another block's temporary
        // folder (`allowed` is in the first rig's) stays closed.
        let home = homeFile
        let own = try temporaryFile("b.png", in: readingRig)
        let readingDrag = ViewNode.ItemDrag([.file(path: home), .file(path: own), .file(path: allowed), .text(string: "hi")])
        let kept = readingRig.block.model.dragPayloads(for: readingDrag)
        #expect(kept.count == 3)
        #expect(kept.compactMap { ($0.writer as? NSURL)?.path } == [home, own], "the other block's file is left out")
        #expect(kept.last?.writer is NSString)
    }

    /// The sandbox opens the screenshot folder the process started with. When
    /// the folder changes, the next screenshot restarts the block first, and
    /// the new process gets the event live after its `welcome`.
    @Test func movedScreenshotFolderRestartsTheBlockBeforeTheEvent() async throws {
        final class Folder { var url = URL(fileURLWithPath: "/tmp/mantel-shots-a") }
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

        folder.url = URL(fileURLWithPath: "/tmp/mantel-shots-b")
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
