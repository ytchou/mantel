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
}
