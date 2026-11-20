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
        let items: [DroppedItem] = [.file(URL(fileURLWithPath: "/tmp/a.png")), .link(URL(string: "https://example.com")!), .text("hi")]

        let current = Rig()
        try await current.process.start()
        try current.process.send(present(accepts: [.file, .link, .text]))
        await waitUntil { current.runtime.state.owner == "hello" }
        current.block.handle(.drop(items))
        _ = await current.process.waitFor { if case .input = $0 { true } else { false } }
        #expect(current.process.inputs == [.drop(items: [.file(path: "/tmp/a.png"), .link(url: "https://example.com"), .text(string: "hi")])])

        let old = Rig()
        try old.process.hello(contract: 1)
        _ = await old.process.waitFor { if case .welcome = $0 { true } else { false } }
        try old.process.send(present(accepts: [.file]))
        await waitUntil { old.runtime.state.owner == "hello" }
        old.block.handle(.drop(items))
        await settle()
        #expect(old.process.inputs.isEmpty)
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
