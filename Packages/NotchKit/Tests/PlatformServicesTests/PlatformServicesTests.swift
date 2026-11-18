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
