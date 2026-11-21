import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

@MainActor
struct SettingsTests {
    /// The settings the first `welcome` carried.
    private func welcomeSettings(_ process: FakeProcess) -> [String: SettingValue]? {
        process.received.lazy.compactMap { message -> [String: SettingValue]? in
            if case let .welcome(_, settings, _) = message { settings } else { nil }
        }.first
    }

    @Test func welcomeCarriesStoredAndDefaultSettings() async throws {
        let defaults = testDefaults()
        defaults.set(true, forKey: "hello.loud")
        let rig = Rig(defaults: defaults)
        try await rig.process.start()

        // A stored value wins; the absent `size` gives the manifest default.
        #expect(welcomeSettings(rig.process) == ["loud": .bool(true), "size": .string("large")])

        let stored = testDefaults()
        stored.set("small", forKey: "hello.size")
        let second = Rig(defaults: stored)
        try await second.process.start()
        #expect(welcomeSettings(second.process) == ["loud": .bool(false), "size": .string("small")])
    }

    @Test func toggleReadFollowsBoolForKey() async throws {
        // A launch argument such as `-hello.loud NO` arrives as a string.
        let defaults = testDefaults()
        defaults.set("NO", forKey: "hello.loud")
        let manifest = Manifest(id: "hello", name: "Hello", version: "1.0.0", executable: "HelloBlock",
                                settings: [SettingSpec(key: "loud", type: .toggle, title: "Loud", default: .bool(true)),
                                           SettingSpec(key: "plain", type: .toggle, title: "Plain")])
        let rig = Rig(manifest: manifest, defaults: defaults)
        try await rig.process.start()

        // "NO" is false; a toggle with no default and nothing stored is on.
        #expect(welcomeSettings(rig.process) == ["loud": .bool(false), "plain": .bool(true)])
    }

    @Test func changingASettingStoresAndPushes() async throws {
        let rig = Rig()
        try await rig.process.start()

        SettingsForm(block: rig.block).toggle("loud").wrappedValue = true
        let pushed = await rig.process.waitFor { if case .setting = $0 { true } else { false } }
        await settle()

        #expect(rig.defaults.object(forKey: "hello.loud") != nil)
        #expect(rig.defaults.bool(forKey: "hello.loud"))
        #expect(pushed == .setting(key: "loud", value: .bool(true)))
        #expect(rig.process.received.filter { if case .setting = $0 { true } else { false } }.count == 1)
        #expect(SettingsForm(block: rig.block).toggle("loud").wrappedValue)

        SettingsForm(block: rig.block).choice("size").wrappedValue = "small"
        #expect(rig.defaults.string(forKey: "hello.size") == "small")
    }

    @Test func settingsPaneIsNilWithoutSettings() {
        let none = Manifest(id: "plain", name: "Plain", version: "1.0.0", executable: "Plain")
        #expect(Rig(manifest: none).block.settingsPane == nil)
        #expect(Rig().block.settingsPane != nil)
    }

    @Test func settingNoteReplacesTheNoteText() async throws {
        let rig = Rig()
        try await rig.process.start()
        #expect(SettingsForm(block: rig.block).noteText(for: "about", title: "A note") == "A note")

        try rig.process.send(.settingNote(key: "about", text: "Model ready"))
        await waitUntil { rig.block.notes["about"] != nil }
        #expect(SettingsForm(block: rig.block).noteText(for: "about", title: "A note") == "Model ready")

        // Only a declared note changes.
        try rig.process.send(.settingNote(key: "loud", text: "Not a note"))
        await settle()
        #expect(rig.block.notes["loud"] == nil)
    }
}
