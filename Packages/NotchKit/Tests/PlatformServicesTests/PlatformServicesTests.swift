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
@Test func blockWithoutInfoGetsTheDefaultAndAnEmptyDetailLine() {
    let block = FakeBlock("plain")
    #expect(block.info == BlockInfo())
    let entry = BlockEntry(id: block.id, title: block.title, info: block.info)
    #expect(entry.detail.isEmpty)
}

@Test func detailLineJoinsTriggerAndPermissions() {
    let both = BlockEntry(id: "a", title: "A", info: BlockInfo(trigger: "Taking a screenshot", permissions: ["Folder access", "Apple Intelligence"]))
    #expect(both.detail == "Taking a screenshot · Needs: Folder access, Apple Intelligence")
    let triggerOnly = BlockEntry(id: "b", title: "B", info: BlockInfo(trigger: "Dragging"))
    #expect(triggerOnly.detail == "Dragging")
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
