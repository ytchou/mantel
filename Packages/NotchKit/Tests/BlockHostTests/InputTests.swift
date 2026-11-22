import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

@MainActor
struct InputTests {
    private func inputs(_ process: FakeProcess) -> [WireInput] {
        process.received.compactMap { if case let .input(input) = $0 { input } else { nil } }
    }

    private func actionsSent(_ process: FakeProcess) -> [String] {
        process.received.compactMap { if case let .action(id) = $0 { id } else { nil } }
    }

    @Test func clickIsForwardedOnlyWhileOwner() async throws {
        let rig = Rig()
        try await rig.process.start()

        // Not the owner yet: nothing goes out.
        rig.block.handle(.click)

        try rig.process.send(present())
        await waitUntil { rig.runtime.state.owner == "hello" }
        rig.block.handle(.click)
        rig.block.handle(.drop([]))
        _ = await rig.process.waitFor { if case .input = $0 { true } else { false } }
        await settle()

        #expect(inputs(rig.process) == [.click])
    }

    @Test func buttonTapSendsItsId() async throws {
        let rig = Rig()
        try await rig.process.start()
        try rig.process.send(present(.button(id: "skip", title: "Skip")))
        await waitUntil { rig.runtime.state.owner == "hello" }

        rig.block.buttonTapped("skip")
        _ = await rig.process.waitFor { if case .input = $0 { true } else { false } }

        #expect(inputs(rig.process) == [.button(id: "skip")])
    }

    @Test func actionsAppearAndPerform() async throws {
        let rig = Rig()
        try await rig.process.start()
        try rig.process.send(.actions(items: [ActionItem(id: "next", title: "Next track"),
                                              ActionItem(id: "pause", title: "Pause", enabled: false)]))
        await waitUntil { rig.block.actions.count == 2 }

        #expect(rig.block.actions.map(\.title) == ["Next track", "Pause"])
        #expect(rig.block.actions.map(\.isEnabled) == [true, false])

        rig.block.actions.first?.perform()
        _ = await rig.process.waitFor { if case .action = $0 { true } else { false } }
        #expect(actionsSent(rig.process) == ["next"])
    }

    @Test func actionsClearOnCrash() async throws {
        let rig = Rig()
        try await rig.process.start()
        try rig.process.send(.actions(items: [ActionItem(id: "next", title: "Next track")]))
        await waitUntil { !rig.block.actions.isEmpty }
        let offered = try #require(rig.block.actions.first)

        rig.process.close()
        await waitUntil { rig.launcher.processes.count == 2 }
        #expect(rig.block.actions.isEmpty)

        // The new process has not offered it: the old action reaches nobody.
        try await rig.process.start()
        offered.perform()
        await settle()
        #expect(actionsSent(rig.process).isEmpty)
        #expect(rig.block.actions.isEmpty)

        try rig.process.send(.actions(items: [ActionItem(id: "again", title: "Again")]))
        await waitUntil { !rig.block.actions.isEmpty }
        #expect(rig.block.actions.map(\.title) == ["Again"])
    }

    // MARK: Contract version 2

    @Test func dropIsForwardedOnlyToAVersion2Block() async throws {
        let file = try finderFile("a.png", "png")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let items: [DroppedItem] = [.file(file), .link(URL(string: "https://example.com")!), .text("hi")]
        // `files.read`, a file in the home folder: its own path goes out.
        var reading = helloManifest
        reading.access = [.filesRead]

        let current = Rig(manifest: reading)
        current.block.homeFolder = file.deletingLastPathComponent()
        try await current.process.start()
        try current.process.send(present(accepts: [.file, .link, .text]))
        await waitUntil { current.runtime.state.owner == "hello" }
        current.block.handle(.drop(items))
        _ = await current.process.waitFor { if case .input = $0 { true } else { false } }
        #expect(current.process.inputs == [.drop(items: [.file(path: file.path), .link(url: "https://example.com"), .text(string: "hi")])])

        let old = Rig(manifest: reading)
        try old.process.hello(contract: 1)
        _ = await old.process.waitFor { if case .welcome = $0 { true } else { false } }
        try old.process.send(present(accepts: [.file]))
        await waitUntil { old.runtime.state.owner == "hello" }
        old.block.handle(.drop(items))
        await settle()
        #expect(old.process.inputs.isEmpty)
    }

    // MARK: Drop hand-over

    /// A rig whose block owns the notch and accepts files and text.
    private func owningRig(_ manifest: Manifest = helloManifest) async throws -> Rig {
        let rig = Rig(manifest: manifest)
        try await rig.process.start()
        try rig.process.send(present(accepts: [.file, .text]))
        await waitUntil { rig.runtime.state.owner == "hello" }
        return rig
    }

    /// `<block temp>/Mantel/Drops`.
    private func drops(_ rig: Rig) -> URL {
        rig.block.temporaryFolder.appending(path: "Mantel/Drops", directoryHint: .isDirectory)
    }

    /// Drops `items` and returns the drop the block got.
    private func dropped(_ items: [DroppedItem], on rig: Rig) async -> [WireDrop] {
        rig.block.handle(.drop(items))
        _ = await rig.process.waitFor { if case .input(.drop) = $0 { true } else { false } }
        return rig.process.inputs.compactMap { if case let .drop(items) = $0 { items } else { nil } }.first ?? []
    }

    private func path(_ drop: WireDrop?) -> String? {
        if case let .file(path) = drop { path } else { nil }
    }

    /// A new file in a fresh folder of the real temporary folder, outside
    /// any rig's folders, as a file from Finder.
    private func finderFile(_ name: String, _ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mantel-finder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func aFileDroppedOnABlockWithoutFileAccessArrivesAsACopy() async throws {
        let rig = try await owningRig()
        let original = try finderFile("notes.txt", "hello")
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }

        let items = await dropped([.file(original), .text("hi")], on: rig)

        #expect(items.count == 2)
        let sent = try #require(path(items.first))
        #expect(sent.hasPrefix(drops(rig).path + "/"))
        #expect(URL(fileURLWithPath: sent).lastPathComponent == "notes.txt")
        #expect(FileManager.default.contents(atPath: sent) == Data("hello".utf8))
        #expect(FileManager.default.contents(atPath: original.path) == Data("hello".utf8))
        #expect(items.last == .text(string: "hi"))
    }

    /// A file in the home folder, which `files.read` opens: its own path.
    /// The test's folder stands in for the home folder.
    @Test func aBlockWithFileAccessGetsTheOriginalPath() async throws {
        var reading = helloManifest
        reading.access = [.filesRead]
        let rig = try await owningRig(reading)
        let original = try finderFile("notes.txt", "hello")
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        rig.block.homeFolder = original.deletingLastPathComponent()

        let items = await dropped([.file(original)], on: rig)

        #expect(items == [.file(path: original.path)])
        #expect(!FileManager.default.fileExists(atPath: drops(rig).path))
    }

    /// `files.read` opens the home folder and `/Volumes` only: a file
    /// elsewhere, such as in the temporary folder, arrives as a copy.
    @Test func aFileOutsideHomeDroppedOnAFileAccessBlockArrivesAsACopy() async throws {
        var reading = helloManifest
        reading.access = [.filesRead]
        let rig = try await owningRig(reading)
        let original = try finderFile("notes.txt", "hello")
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        // A home folder that does not hold the file.
        rig.block.homeFolder = FileManager.default.temporaryDirectory.appending(path: "mantel-home-\(UUID().uuidString)")

        let items = await dropped([.file(original)], on: rig)

        let sent = try #require(path(items.first))
        #expect(items.count == 1)
        #expect(sent.hasPrefix(drops(rig).path + "/"))
        #expect(URL(fileURLWithPath: sent).lastPathComponent == "notes.txt")
        #expect(FileManager.default.contents(atPath: sent) == Data("hello".utf8))
        #expect(FileManager.default.contents(atPath: original.path) == Data("hello".utf8))
    }

    /// A file the shell wrote into the drop folder is moved into the block's
    /// own temporary folder, under the same `<uuid>` folder, for a block
    /// with or without `files.read`. Other blocks cannot read it there.
    @Test func aPromisedFileIsStillMoved() async throws {
        var reading = helloManifest
        reading.access = [.filesRead]
        for manifest in [helloManifest, reading] {
            let rig = try await owningRig(manifest)
            let promised = rig.dropFolder.appending(path: "UUID-1/shot.png")
            try FileManager.default.createDirectory(at: promised.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("png".utf8).write(to: promised)
            let missing = rig.dropFolder.appending(path: "UUID-2/gone.png")

            let items = await dropped([.file(promised), .file(missing), .text("hi")], on: rig)

            let moved = drops(rig).appending(path: "UUID-1/shot.png")
            #expect(items == [.file(path: moved.path), .text(string: "hi")])
            #expect(FileManager.default.contents(atPath: moved.path) == Data("png".utf8))
            #expect(!FileManager.default.fileExists(atPath: promised.path))
        }
    }

    @Test func aDroppedFolderIsCopiedWhole() async throws {
        let rig = try await owningRig()
        let folder = FileManager.default.temporaryDirectory.appending(path: "mantel-finder-\(UUID().uuidString)/Photos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "Inner"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appending(path: "a.txt"))
        try Data("b".utf8).write(to: folder.appending(path: "Inner/b.txt"))
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let items = await dropped([.file(folder)], on: rig)

        let sent = try #require(path(items.first))
        #expect(sent.hasPrefix(drops(rig).path + "/"))
        #expect(URL(fileURLWithPath: sent).lastPathComponent == "Photos")
        #expect(FileManager.default.contents(atPath: sent + "/a.txt") == Data("a".utf8))
        #expect(FileManager.default.contents(atPath: sent + "/Inner/b.txt") == Data("b".utf8))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Inner/b.txt").path))
    }

    @Test func aFileThatCannotBeCopiedIsLeftOutAndTheRestArrive() async throws {
        let rig = try await owningRig()
        let kept = try finderFile("kept.txt", "kept")
        defer { try? FileManager.default.removeItem(at: kept.deletingLastPathComponent()) }
        let missing = kept.deletingLastPathComponent().appending(path: "gone.txt")

        let items = await dropped([.file(missing), .file(kept), .text("hi")], on: rig)

        #expect(items.count == 2)
        let sent = try #require(path(items.first))
        #expect(URL(fileURLWithPath: sent).lastPathComponent == "kept.txt")
        #expect(FileManager.default.contents(atPath: sent) == Data("kept".utf8))
        #expect(items.last == .text(string: "hi"))
    }

    /// The volume and size check is injected: both files count as on
    /// another volume, one over `crossVolumeCopyLimit`, one under it.
    @Test func aLargeFileOnAnotherVolumeIsLeftOut() async throws {
        let rig = try await owningRig()
        let big = try finderFile("big.bin", "big")
        let small = try finderFile("small.bin", "small")
        defer {
            try? FileManager.default.removeItem(at: big.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: small.deletingLastPathComponent())
        }
        rig.block.crossVolumeSize = { source, _ in
            source.lastPathComponent == "big.bin" ? RemoteBlock.crossVolumeCopyLimit + 1 : 1_000
        }

        let items = await dropped([.file(big), .file(small)], on: rig)

        #expect(items.count == 1)
        let sent = try #require(path(items.first))
        #expect(URL(fileURLWithPath: sent).lastPathComponent == "small.bin")
        #expect(FileManager.default.contents(atPath: sent) == Data("small".utf8))
    }

    @Test func theDropsTempIsEmptiedAtStart() async throws {
        let rig = try await owningRig()
        let leftover = drops(rig).appending(path: "OLD/left.txt")
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: leftover)

        // The process ends; the block starts again.
        rig.process.close()
        await waitUntil { rig.launcher.processes.count == 2 }

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: rig.block.temporaryFolder.path))
    }

    @Test func itemActionAndDragMessagesReachTheBlock() async throws {
        var manifest = helloManifest
        manifest.events = ["dragStarted", "dragEnded"]
        let rig = Rig(manifest: manifest)
        try await rig.process.start()

        rig.block.model.onItemAction("tile-1", .doubleClick)
        rig.block.model.onItemAction("tile-1", .menu(id: "open"))
        // As the item layer does: dragBegan, then the system drag starts and
        // the drag monitor publishes it.
        _ = rig.block.model.beginItemDrag("tile-1")
        rig.runtime.dragSessionChanged(active: true)
        rig.runtime.publish(DragSessionStarted(kinds: [.file]))
        rig.block.model.onDragEnded("tile-1", true)
        _ = await rig.process.waitFor { if case .input(.dragEnded) = $0 { true } else { false } }

        #expect(rig.process.inputs == [
            .item(id: "tile-1", action: .doubleClick),
            .item(id: "tile-1", action: .menu(id: "open")),
            .dragBegan(id: "tile-1"),
            .dragEnded(id: "tile-1", succeeded: true),
        ])
        let began = rig.process.received.firstIndex { if case .input(.dragBegan) = $0 { true } else { false } }
        let started = rig.process.received.firstIndex {
            if case let .event(payload, _, _) = $0, payload.name == .dragStarted { true } else { false }
        }
        let beganIndex = try #require(began)
        let startedIndex = try #require(started)
        #expect(beganIndex < startedIndex, "dragBegan goes out before the dragStarted event")
    }
}
