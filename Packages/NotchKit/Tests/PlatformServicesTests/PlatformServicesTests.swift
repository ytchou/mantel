import Foundation
import NotchCore
import Testing
@testable import PlatformServices

@MainActor
private final class FakeBlock: NotchBlock {
    let id: BlockID
    let title = "Fake"
    private(set) var activations = 0
    private(set) var deactivations = 0

    init(_ id: BlockID) { self.id = id }

    func activate(_ context: any BlockContext) { activations += 1 }
    func deactivate() { deactivations += 1 }
}

/// A fresh, empty UserDefaults suite. Removed again by `cleanUp`.
private func makeDefaults() -> (UserDefaults, String) {
    let name = "PlatformServicesTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

private func cleanUp(_ defaults: UserDefaults, _ name: String) {
    defaults.removePersistentDomain(forName: name)
}

// MARK: - BlockSettings

@MainActor
@Test func blockWithNoStoredValueIsOn() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults)

    #expect(settings.isEnabled("a"))
}

@MainActor
@Test func turningOffPersistsAndDisablesInRuntime() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults)
    let runtime = NotchRuntime()
    let block = FakeBlock("a")
    runtime.register(block, enabled: settings.isEnabled(block.id))

    settings.setEnabled("a", false, in: runtime)

    #expect(!settings.isEnabled("a"))
    #expect(!runtime.isEnabled("a"))
    #expect(block.deactivations == 1)
    #expect(defaults.object(forKey: "block.a.enabled") as? Bool == false)
}

@MainActor
@Test func turningOnAgainReEnables() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults)
    let runtime = NotchRuntime()
    let block = FakeBlock("a")
    runtime.register(block)

    settings.setEnabled("a", false, in: runtime)
    settings.setEnabled("a", true, in: runtime)

    #expect(settings.isEnabled("a"))
    #expect(runtime.isEnabled("a"))
    #expect(block.activations == 2)
}

@MainActor
@Test func valueIsReadBackByNewInstance() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let runtime = NotchRuntime()
    runtime.register(FakeBlock("a"))
    runtime.register(FakeBlock("b"))

    BlockSettings(defaults: defaults).setEnabled("a", false, in: runtime)
    let reloaded = BlockSettings(defaults: defaults)

    #expect(!reloaded.isEnabled("a"))
    #expect(reloaded.isEnabled("b"))
}

// MARK: - Screenshot folder

private let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)

@Test func missingLocationIsDesktop() {
    let url = ScreenshotFolder.resolve(location: nil, home: home)
    #expect(url.path(percentEncoded: false) == "/Users/test/Desktop/")
}

@Test func emptyLocationIsDesktop() {
    let url = ScreenshotFolder.resolve(location: "", home: home)
    #expect(url.path(percentEncoded: false) == "/Users/test/Desktop/")
}

@Test func tildeLocationIsExpanded() {
    let url = ScreenshotFolder.resolve(location: "~/Pictures/Shots", home: home)
    #expect(url.path(percentEncoded: false) == "/Users/test/Pictures/Shots/")
}

@Test func absoluteLocationIsKept() {
    let url = ScreenshotFolder.resolve(location: "/Volumes/Data/Shots", home: home)
    #expect(url.path(percentEncoded: false) == "/Volumes/Data/Shots/")
}

// MARK: - Onboarding flag

@MainActor
@Test func onboardingCompletedFlagPersists() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let controller = OnboardingController(defaults: defaults)
    #expect(!controller.isCompleted)

    controller.markCompleted()

    #expect(controller.isCompleted)
    #expect(defaults.bool(forKey: "onboarding.completed"))
    #expect(OnboardingController(defaults: defaults).isCompleted)
}

@MainActor
@Test func blockWithoutInfoGetsTheDefaultAndOnlyTheSourceInTheDetailLine() {
    let block = FakeBlock("plain")
    #expect(block.info == BlockInfo())
    let entry = BlockEntry(id: block.id, title: block.title, info: block.info)
    #expect(entry.detail == "Built in")
}

@Test func detailLineJoinsTriggerAndPermissions() {
    let both = BlockEntry(id: "a", title: "A", info: BlockInfo(trigger: "Taking a screenshot", permissions: ["Folder access", "Apple Intelligence"]))
    #expect(both.detail == "Built in · Taking a screenshot · Needs: Folder access, Apple Intelligence")
    let triggerOnly = BlockEntry(id: "b", title: "B", info: BlockInfo(trigger: "Dragging"))
    #expect(triggerOnly.detail == "Built in · Dragging")
}

@MainActor
@Test func aLaunchArgumentStringTurnsABlockOff() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    // Launch arguments reach UserDefaults as strings, not booleans.
    defaults.set("NO", forKey: "block.shelf.enabled")
    defaults.set("YES", forKey: "block.rename.enabled")
    let settings = BlockSettings(defaults: defaults)
    #expect(settings.isEnabled("shelf") == false)
    #expect(settings.isEnabled("rename") == true)
    #expect(settings.isEnabled("unset") == true)
}

@MainActor
private final class ActionBlock: NotchBlock {
    let id: BlockID
    let title: String
    var ran = 0
    init(_ id: BlockID, title: String) { self.id = id; self.title = title }
    func activate(_ context: any BlockContext) {}
    var actions: [BlockAction] {
        [BlockAction(id: "go", title: "Go") { [weak self] in self?.ran += 1 },
         BlockAction(id: "stop", title: "Stop", isEnabled: false) {}]
    }
}

@MainActor
@Test func notchMenuListsEnabledBlocksActionsThenSettingsAndQuit() {
    let runtime = NotchRuntime()
    let on = ActionBlock("on", title: "On Block")
    runtime.register(on)
    runtime.register(ActionBlock("off", title: "Off Block"), enabled: false)
    runtime.register(FakeBlock("plain"))
    var opened = 0
    let notchMenu = NotchMenu(runtime: runtime) { opened += 1 }

    let menu = notchMenu.make()
    let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    #expect(titles == ["On Block", "Go", "Stop", "Settings\u{2026}", "Quit TopNotch"])
    #expect(menu.item(withTitle: "Go")?.isEnabled == true)
    #expect(menu.item(withTitle: "Stop")?.isEnabled == false)

    // Sent straight to the item's target: a test process has no running NSApp to route it.
    func click(_ title: String) {
        guard let item = menu.item(withTitle: title), let action = item.action else { return }
        _ = item.target?.perform(action, with: item)
    }
    click("Go")
    #expect(on.ran == 1)
    click("Settings\u{2026}")
    #expect(opened == 1)
}

// MARK: - Install, update, remove

@MainActor
@Test func clearRemovesOnlyThatBlocksKeys() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    defaults.set(true, forKey: "hello.loud")
    defaults.set("big", forKey: "hello.size")
    defaults.set(false, forKey: "block.hello.enabled")
    defaults.set("Stopped.", forKey: "block.hello.failure")
    defaults.set(true, forKey: "hello-world.loud")
    defaults.set(true, forKey: "shelf.keep")
    defaults.set(false, forKey: "block.shelf.enabled")
    defaults.set(true, forKey: "onboarding.completed")
    let settings = BlockSettings(defaults: defaults)

    settings.clear("hello")

    for key in ["hello.loud", "hello.size", "block.hello.enabled", "block.hello.failure"] {
        #expect(defaults.object(forKey: key) == nil, "\(key) was cleared")
    }
    #expect(defaults.bool(forKey: "hello-world.loud"))
    #expect(defaults.bool(forKey: "shelf.keep"))
    #expect(defaults.object(forKey: "block.shelf.enabled") as? Bool == false)
    #expect(defaults.bool(forKey: "onboarding.completed"))
    #expect(settings.isEnabled("hello"), "a block with no stored value is on again")
}

/// A block with chosen info and health, as a stand-in would report them.
@MainActor
private final class InfoBlock: NotchBlock {
    let id: BlockID
    let title: String
    let info: BlockInfo
    var health: BlockHealth
    init(_ id: BlockID, info: BlockInfo, health: BlockHealth = .ok) {
        self.id = id
        title = id.rawValue.capitalized
        self.info = info
        self.health = health
    }
    func activate(_ context: any BlockContext) {}
}

/// Answers `canRemove` with yes for every id, so the entry's own rule is what is checked.
@MainActor
private final class FakeInstaller: BlockInstalling {
    func inspect(_ url: URL) throws -> BlockPackageSummary {
        BlockPackageSummary(id: "x", name: "X", version: "1", contract: 1, sourcePath: url.path)
    }
    func install(_ url: URL) throws {}
    func remove(_ id: BlockID) throws {}
    func canRemove(_ id: BlockID) -> Bool { true }
}

@MainActor
@Test func detailShowsSourceAndVersion() {
    let home = "/Users/test"
    let shelf = BlockEntry(block: InfoBlock("shelf", info: BlockInfo(trigger: "Dragging files")), installer: nil, home: home)
    #expect(shelf.detail == "Built in · Dragging files")

    let bundled = BlockEntry(block: InfoBlock("nowplaying", info: BlockInfo(trigger: "Music", version: "1.0", source: .bundled)),
                             installer: nil, home: home)
    #expect(bundled.detail == "Built in · 1.0 · Music")

    let installed = BlockEntry(
        block: InfoBlock("hello", info: BlockInfo(trigger: "Pointer hover", version: "0.2",
                                                  source: .installed(from: "/Users/test/dev/hello-block"))),
        installer: nil, home: home)
    #expect(installed.detail == "Installed from ~/dev/hello-block · 0.2 · Pointer hover")

    let development = BlockEntry(
        block: InfoBlock("dev", info: BlockInfo(trigger: "Pointer hover", version: "0.1",
                                                source: .development(path: "/tmp/Dev.topblock"))),
        installer: nil, home: home)
    #expect(development.detail == "Development · /tmp/Dev.topblock · 0.1 · Pointer hover")
}

@MainActor
@Test func turnedOffEntryShowsReason() {
    let block = InfoBlock("hello", info: BlockInfo(source: .installed(from: "/tmp/Hello.topblock")),
                          health: .turnedOff(reason: "It stopped 3 times in a minute."))
    let entry = BlockEntry(block: block, installer: nil)
    #expect(entry.turnedOffReason == "It stopped 3 times in a minute.")
    #expect(entry.offersTurnOn)

    let healthy = BlockEntry(block: InfoBlock("ok", info: BlockInfo()), installer: nil)
    #expect(healthy.turnedOffReason == nil)
    #expect(!healthy.offersTurnOn)
}

@MainActor
@Test func restartCountIsShown() {
    let block = InfoBlock("hello", info: BlockInfo(trigger: "Pointer hover"), health: .restarting(count: 1))
    #expect(BlockEntry(block: block, installer: nil).detail == "Built in · Pointer hover · Restarted once")
    block.health = .restarting(count: 3)
    #expect(BlockEntry(block: block, installer: nil).detail == "Built in · Pointer hover · Restarted 3 times")
}

@MainActor
@Test func removeOfferedOnlyWhenRemovable() {
    let installer = FakeInstaller()
    let installed = InfoBlock("hello", info: BlockInfo(source: .installed(from: "/tmp/Hello.topblock")))
    let bundled = InfoBlock("nowplaying", info: BlockInfo(source: .bundled))
    let builtIn = InfoBlock("shelf", info: BlockInfo())
    #expect(BlockEntry(block: installed, installer: installer).isRemovable)
    #expect(!BlockEntry(block: bundled, installer: installer).isRemovable)
    #expect(!BlockEntry(block: builtIn, installer: installer).isRemovable)
    #expect(!BlockEntry(block: installed, installer: nil).isRemovable, "nothing is removable without an installer")
}

@MainActor
@Test func selectionFallsBackAfterRemove() {
    let runtime = NotchRuntime()
    runtime.register(FakeBlock("shelf"))
    runtime.register(FakeBlock("hello"))
    let ids = { runtime.blocks.map(\.id) }
    #expect(SettingsPane.block("hello").remaining(in: ids()) == .block("hello"))

    runtime.unregister("hello")

    #expect(SettingsPane.block("hello").remaining(in: ids()) == .blocks)
    #expect(SettingsPane.block("shelf").remaining(in: ids()) == .block("shelf"))
    #expect(SettingsPane.general.remaining(in: ids()) == .general)
}

@Test func summaryMarksNewEvents() {
    let update = BlockPackageSummary(id: "hello", name: "Hello", version: "0.3", contract: 1,
                                     events: ["Pointer over the notch", "Volume changes"], newEvents: ["Volume changes"],
                                     permissions: [], sourcePath: "/tmp/Hello.topblock", installedVersion: "0.2")
    let text = InstallSheetText(update)
    #expect(text.events == ["Pointer over the notch", "Volume changes (new)"])
    #expect(text.isUpdate)
    #expect(text.title == "Update Hello?")
    #expect(text.version == "0.3 (installed: 0.2)")
    #expect(text.confirm == "Update")
    #expect(text.keeps == "Its settings and data are kept.")
    #expect(text.permissions == "Nothing")

    let fresh = BlockPackageSummary(id: "hello", name: "Hello", version: "0.2", contract: 1,
                                    events: ["Pointer over the notch"], permissions: ["Reads the clipboard"],
                                    sourcePath: "/tmp/Hello.topblock")
    let freshText = InstallSheetText(fresh)
    #expect(freshText.events == ["Pointer over the notch"])
    #expect(!freshText.isUpdate)
    #expect(freshText.title == "Install Hello?")
    #expect(freshText.version == "0.2")
    #expect(freshText.contract == "Block contract 1")
    #expect(freshText.confirm == "Install and Turn On")
    #expect(freshText.keeps == nil)
    #expect(freshText.permissions == "Reads the clipboard")
}
