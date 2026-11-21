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

/// A block that listens to screenshots once turned on.
@MainActor
private final class ScreenshotListener: NotchBlock {
    let id: BlockID
    let title = "Screenshots"
    init(_ id: BlockID) { self.id = id }
    func activate(_ context: any BlockContext) {
        context.subscribe(to: ScreenshotCaptured.self) { _ in }
    }
}

@MainActor
@Test func permissionRowsShowOnlyWhenABlockNeedsThem() {
    let runtime = NotchRuntime()
    // No block: the General page and onboarding show no screenshot-folder row.
    #expect(PermissionRow.rows(in: runtime) == [.appleIntelligence])

    // A block that does not listen to screenshots, and one registered turned off.
    runtime.register(FakeBlock("other"))
    runtime.register(ScreenshotListener("shots"), enabled: false)
    #expect(PermissionRow.rows(in: runtime) == [.appleIntelligence])

    runtime.setEnabled("shots", true)
    #expect(PermissionRow.rows(in: runtime) == [.screenshotFolder, .appleIntelligence])

    runtime.setEnabled("shots", false)
    #expect(PermissionRow.rows(in: runtime) == [.appleIntelligence])
}

/// The Blocks page switch reaches the runtime's demand change, which is what
/// starts the screenshot source and its consent check: no extra call is needed.
@MainActor
@Test func turningABlockOnInSettingsReportsTheDemandChange() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults)
    let runtime = NotchRuntime()
    var changes = 0
    runtime.onDemandChanged = { changes += 1 }
    runtime.register(ScreenshotListener("shots"), enabled: false)
    #expect(changes == 0)

    settings.setEnabled("shots", true, in: runtime)

    #expect(changes == 1)
    #expect(runtime.hasSubscribers(for: ScreenshotCaptured.self))
}

/// The settings rows ask for the folder NotchCore resolves, the one the
/// screenshot watcher reads (`theWatcherReadsTheSharedScreenshotFolder`).
@MainActor
@Test func thereIsOneScreenshotFolderDefinition() {
    #expect(FolderAccessRow().folder == NotchCore.ScreenshotFolder.current())
    let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    let url = NotchCore.ScreenshotFolder.resolve(location: "~/Pictures/Shots", home: home) { _ in true }
    #expect(url.path(percentEncoded: false) == "/Users/test/Pictures/Shots/")
}

// MARK: - Onboarding flag

@MainActor
@Test func onboardingCompletedFlagPersists() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let controller = OnboardingController(runtime: NotchRuntime(), defaults: defaults)
    #expect(!controller.isCompleted)

    controller.markCompleted()

    #expect(controller.isCompleted)
    #expect(defaults.bool(forKey: "onboarding.completed"))
    #expect(OnboardingController(runtime: NotchRuntime(), defaults: defaults).isCompleted)
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
    let settings = BlockSettings(defaults: defaults, domain: name)

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

@MainActor
@Test func clearLooksOnlyAtTheAppsOwnKeys() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    defaults.set(true, forKey: "hello.loud")
    // Seen through `dictionaryRepresentation()`, but not stored by the app.
    defaults.register(defaults: ["hello.registered": true])
    let settings = BlockSettings(defaults: defaults, domain: name)

    #expect(settings.storedKeys(of: "hello") == ["hello.loud"])
}

/// A block with chosen info and health, as a stand-in would report them.
@MainActor
private final class InfoBlock: NotchBlock {
    let id: BlockID
    let title: String
    let info: BlockInfo
    var health: BlockHealth
    var usage: BlockUsage?
    var review: BlockReview?
    var notice: String?
    init(_ id: BlockID, info: BlockInfo, health: BlockHealth = .ok, usage: BlockUsage? = nil,
         review: BlockReview? = nil, notice: String? = nil) {
        self.id = id
        title = id.rawValue.capitalized
        self.info = info
        self.health = health
        self.usage = usage
        self.review = review
        self.notice = notice
    }
    /// As a stand-in does: turned on, earlier failures no longer count.
    func activate(_ context: any BlockContext) { health = .ok }
}

/// Answers `canRemove` and `canTurnOn` from the ids it is given.
@MainActor
private final class FakeInstaller: BlockInstalling {
    let removable: Set<BlockID>
    let cannotRun: Set<BlockID>
    init(removable: Set<BlockID> = [], cannotRun: Set<BlockID> = []) {
        self.removable = removable
        self.cannotRun = cannotRun
    }
    func inspect(_ url: URL) throws -> BlockPackageSummary {
        BlockPackageSummary(id: "x", name: "X", version: "1", contract: 1, sourcePath: url.path)
    }
    func install(_ url: URL) throws {}
    func approve(_ id: BlockID) throws {}
    func remove(_ id: BlockID) throws {}
    func canRemove(_ id: BlockID) -> Bool { removable.contains(id) }
    func canTurnOn(_ id: BlockID) -> Bool { !cannotRun.contains(id) }
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
@Test func refusedPackageShowsReasonWithoutTurnOn() {
    let block = InfoBlock("old", info: BlockInfo(source: .installed(from: "/tmp/Old.topblock")),
                          health: .turnedOff(reason: "Built for contract 99."))
    let installer = FakeInstaller(removable: ["old"], cannotRun: ["old"])
    let entry = BlockEntry(block: block, installer: installer)
    #expect(entry.turnedOffReason == "Built for contract 99.")
    #expect(!entry.offersTurnOn, "turning it on cannot start it")
    #expect(entry.isRemovable)
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
    // The installer alone decides.
    let installer = FakeInstaller(removable: ["hello"])
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

@Test func updateRefusesPackageOfAnotherBlock() throws {
    let other = BlockPackageSummary(id: "other", name: "Other", version: "1.0", contract: 1, sourcePath: "/tmp/Other.topblock")

    #expect(other.refusal(updating: "hello") == .differentBlock(expected: "hello", found: "other"))
    #expect(other.refusal(updating: "other") == nil)
    #expect(other.refusal(updating: nil) == nil, "Install Block… takes any id")
    let text = try #require(BlockInstallError.differentBlock(expected: "hello", found: "other").errorDescription)
    #expect(text.contains("\"hello\"") && text.contains("\"other\""))
}

private let hover = EventEntry(name: "Pointer over the notch", reveals: "The pointer entered or left the notch")
private let volume = EventEntry(name: "Volume changes", reveals: "The output volume and mute state")

@Test func summaryMarksNewEvents() {
    let update = BlockPackageSummary(id: "hello", name: "Hello", version: "0.3", contract: 1,
                                     events: ["Pointer over the notch", "Volume changes"], newEvents: ["Volume changes"],
                                     eventEntries: [hover, volume],
                                     permissions: [], sourcePath: "/tmp/Hello.topblock", installedVersion: "0.2")
    let text = InstallSheetText(update)
    #expect(text.events.map(\.name) == ["Pointer over the notch", "Volume changes (new)"])
    #expect(text.isUpdate)
    #expect(text.title == "Update Hello?")
    #expect(text.version == "0.3 (installed: 0.2)")
    #expect(text.confirm == "Update")
    #expect(text.keeps == "Its settings and data are kept.")

    let fresh = BlockPackageSummary(id: "hello", name: "Hello", version: "0.2", contract: 1,
                                    events: ["Pointer over the notch"], eventEntries: [hover],
                                    permissions: ["Reads the clipboard"], sourcePath: "/tmp/Hello.topblock")
    let freshText = InstallSheetText(fresh)
    #expect(freshText.events.map(\.name) == ["Pointer over the notch"])
    #expect(!freshText.isUpdate)
    #expect(freshText.title == "Install Hello?")
    #expect(freshText.version == "0.2")
    #expect(freshText.contract == "Block contract 1")
    #expect(freshText.confirm == "Install and Turn On")
    #expect(freshText.keeps == nil)
    #expect(freshText.access == "Nothing")
}

// MARK: - Install and review sheet

@Test func theSheetListsEachEventWithWhatItReveals() {
    let shots = EventEntry(name: "Screenshots", reveals: "The path and time of a new screenshot", permission: .screenshotFolder)
    let music = EventEntry(name: "Music playing", reveals: "Player, state, title, artist, artwork",
                           note: "Other players are read from an undocumented part of macOS")
    let summary = BlockPackageSummary(id: "hello", name: "Hello", version: "1.0", contract: 3,
                                      eventEntries: [hover, shots, music], sourcePath: "/tmp/Hello.topblock")

    let events = InstallSheetText(summary).events

    #expect(events == [
        .init(name: "Pointer over the notch", reveals: "The pointer entered or left the notch",
              permission: "No macOS permission", note: nil),
        .init(name: "Screenshots", reveals: "The path and time of a new screenshot",
              permission: "Access to the screenshot folder", note: nil),
        .init(name: "Music playing", reveals: "Player, state, title, artist, artwork",
              permission: "No macOS permission", note: "Other players are read from an undocumented part of macOS"),
    ])
}

@Test func theSheetListsHostsUnderCanReach() {
    let network = BlockPackageSummary(id: "weather", name: "Weather Peek", version: "1.2.0", contract: 3,
                                      sourcePath: "/tmp/Weather.topblock", access: ["Use the network"],
                                      signer: "Ana Lima", hosts: ["api.open-meteo.com", "*.example.org"])
    let text = InstallSheetText(network)
    #expect(text.hosts == ["api.open-meteo.com", "*.example.org"])
    #expect(text.access == "Use the network")

    let none = BlockPackageSummary(id: "hello", name: "Hello", version: "1.0", contract: 3, sourcePath: "/tmp/Hello.topblock")
    #expect(InstallSheetText(none).hosts.isEmpty, "no Can reach row")
}

@Test func aRiskyPairNeedsTheSecondConfirmation() {
    let files = BlockPackageSummary(id: "share", name: "Drop to Share", version: "0.4.0", contract: 3,
                                    sourcePath: "/tmp/Share.topblock", access: ["Read your files", "Use the network"],
                                    signer: "Ana Lima", hosts: ["api.dropbox.com", "content.dropboxapi.com"], riskyPair: .files)
    let text = InstallSheetText(files)
    #expect(text.warning == "This block can read your files and send data to api.dropbox.com and content.dropboxapi.com. Install it only if you trust its creator.")
    #expect(text.acknowledgement == "I understand that this block can send my files to these hosts")
    #expect(!text.canConfirm(acknowledged: false))
    #expect(text.canConfirm(acknowledged: true))

    var screenshots = files
    screenshots.riskyPair = .screenshots
    screenshots.hosts = ["a.example.com", "b.example.com", "c.example.com"]
    let shotsText = InstallSheetText(screenshots)
    #expect(shotsText.warning == "This block can read your screenshots and send data to a.example.com, b.example.com and c.example.com. Install it only if you trust its creator.")
    #expect(!shotsText.canConfirm(acknowledged: false))
}

@Test func aSafeBlockNeedsNoSecondConfirmation() {
    let network = BlockPackageSummary(id: "weather", name: "Weather Peek", version: "1.2.0", contract: 3,
                                      sourcePath: "/tmp/Weather.topblock", access: ["Use the network"],
                                      signer: "Ana Lima", hosts: ["api.open-meteo.com"])
    let text = InstallSheetText(network)
    #expect(text.warning == nil)
    #expect(text.acknowledgement == nil)
    #expect(text.canConfirm(acknowledged: false))
}

@Test func anUnsignedBlockSaysTheCreatorCannotBeVerified() {
    let unsigned = BlockPackageSummary(id: "hello", name: "My Hello", version: "0.1.0", contract: 3,
                                       sourcePath: "/tmp/My Hello.topblock")
    let text = InstallSheetText(unsigned)
    #expect(text.creator == "No signature: the creator cannot be verified")
    #expect(text.creatorNote == "Your approval covers this exact build. A changed copy asks again.")

    let signed = BlockPackageSummary(id: "hello", name: "My Hello", version: "0.1.0", contract: 3,
                                     sourcePath: "/tmp/My Hello.topblock", signer: "Jane Developer")
    let signedText = InstallSheetText(signed)
    #expect(signedText.creator == "Jane Developer")
    #expect(signedText.creatorNote == nil)
}

@Test func anUpdateThatAddsAHostNamesTheNewHost() {
    let update = BlockPackageSummary(id: "weather", name: "Weather Peek", version: "1.3.0", contract: 3,
                                     sourcePath: "/tmp/Weather.topblock", installedVersion: "1.2.0",
                                     access: ["Use the network"], signer: "Ana Lima",
                                     hosts: ["api.open-meteo.com", "cdn.open-meteo.com"], newHosts: ["cdn.open-meteo.com"])
    #expect(InstallSheetText(update).hosts == ["api.open-meteo.com", "cdn.open-meteo.com (new)"])
}

@Test func theSheetServesInstallUpdateAndReview() {
    let summary = BlockPackageSummary(id: "weather", name: "Weather Peek", version: "1.2.0", contract: 3,
                                      sourcePath: "/tmp/Weather.topblock")
    #expect(InstallSheetText(summary).confirm == "Install and Turn On")
    let review = InstallSheetText(summary, review: true)
    #expect(review.confirm == "Approve and Turn On")
    #expect(review.title == "Approve Weather Peek?")
    #expect(review.keeps == nil)
}

// MARK: - Order, access, signer, the switch

@MainActor
@Test func orderIsStoredAndRestored() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let runtime = NotchRuntime()
    for id: BlockID in ["shelf", "nowplaying", "rename"] { runtime.register(FakeBlock(id)) }
    let settings = BlockSettings(defaults: defaults, domain: name)

    settings.move("rename", to: 0, in: runtime)

    #expect(runtime.blocks.map(\.id) == ["rename", "shelf", "nowplaying"])
    #expect(defaults.stringArray(forKey: "block.order") == ["rename", "shelf", "nowplaying"])

    // At the next launch, blocks register in any order; a new one is not in the stored list.
    let relaunched = NotchRuntime()
    for id: BlockID in ["hello", "shelf", "nowplaying", "rename"] { relaunched.register(FakeBlock(id)) }
    BlockSettings(defaults: defaults, domain: name).applyOrder(to: relaunched)

    #expect(relaunched.blocks.map(\.id) == ["rename", "shelf", "nowplaying", "hello"])
}

/// The app's register closure for a block installed after launch: register,
/// then apply the stored order again. A block the order ranks first, such as
/// one reinstalled after it was refused, goes first now, not only at the next launch.
@MainActor
@Test func applyingTheOrderAfterALateRegistrationRanksTheNewBlock() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults, domain: name)
    settings.setOrder(["hello", "shelf", "nowplaying"])
    let runtime = NotchRuntime()
    for id: BlockID in ["shelf", "nowplaying"] { runtime.register(FakeBlock(id)) }
    settings.applyOrder(to: runtime)

    runtime.register(FakeBlock("hello"))
    #expect(runtime.blocks.map(\.id) == ["shelf", "nowplaying", "hello"], "register alone puts it last")
    settings.applyOrder(to: runtime)

    #expect(runtime.blocks.map(\.id) == ["hello", "shelf", "nowplaying"])
}

/// No id is ranked by name in code: with nothing stored, the blocks keep the
/// order they were registered in (bundled by package name, then installed).
@MainActor
@Test func withNothingStoredTheRegistrationOrderIsKept() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults, domain: name)
    #expect(settings.order.isEmpty)

    let runtime = NotchRuntime()
    for id: BlockID in ["nowplaying", "rename", "shelf", "hello"] { runtime.register(FakeBlock(id)) }
    settings.applyOrder(to: runtime)

    #expect(runtime.blocks.map(\.id) == ["nowplaying", "rename", "shelf", "hello"])
    #expect(defaults.object(forKey: "block.order") == nil, "applying the order at launch stores nothing")
}

@MainActor
@Test func aStoredOrderWinsOverTheRegistrationOrder() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults, domain: name)
    settings.setOrder(["rename", "shelf"])
    #expect(settings.order == ["rename", "shelf"])

    let runtime = NotchRuntime()
    for id: BlockID in ["nowplaying", "rename", "shelf"] { runtime.register(FakeBlock(id)) }
    settings.applyOrder(to: runtime)

    #expect(runtime.blocks.map(\.id) == ["rename", "shelf", "nowplaying"])
}

/// The app's register closure for a block installed from the Blocks page:
/// the new block goes last and the order is stored, so the install order
/// survives a relaunch, where installed blocks are found sorted by id.
@MainActor
@Test func anInstallAppendsTheBlockAndStoresTheOrder() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults, domain: name)
    let runtime = NotchRuntime()
    for id: BlockID in ["nowplaying", "rename", "shelf"] { runtime.register(FakeBlock(id)) }
    settings.applyOrder(to: runtime)

    runtime.register(FakeBlock("zeta"))
    settings.applyOrderAfterInstall(to: runtime)
    runtime.register(FakeBlock("alpha"))
    settings.applyOrderAfterInstall(to: runtime)

    #expect(runtime.blocks.map(\.id) == ["nowplaying", "rename", "shelf", "zeta", "alpha"])
    #expect(defaults.stringArray(forKey: "block.order") == ["nowplaying", "rename", "shelf", "zeta", "alpha"])

    // At the next launch the installed blocks register sorted by id.
    let relaunched = NotchRuntime()
    for id: BlockID in ["nowplaying", "rename", "shelf", "alpha", "zeta"] { relaunched.register(FakeBlock(id)) }
    BlockSettings(defaults: defaults, domain: name).applyOrder(to: relaunched)

    #expect(relaunched.blocks.map(\.id) == ["nowplaying", "rename", "shelf", "zeta", "alpha"])
}

/// An install keeps the owner's order: the new block goes after it, and
/// stored ids of blocks not registered now are kept.
@MainActor
@Test func anInstallKeepsTheStoredOrder() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults, domain: name)
    settings.setOrder(["rename", "gone", "shelf", "nowplaying"])
    let runtime = NotchRuntime()
    for id: BlockID in ["nowplaying", "rename", "shelf"] { runtime.register(FakeBlock(id)) }
    settings.applyOrder(to: runtime)

    runtime.register(FakeBlock("hello"))
    settings.applyOrderAfterInstall(to: runtime)

    #expect(runtime.blocks.map(\.id) == ["rename", "shelf", "nowplaying", "hello"])
    #expect(defaults.stringArray(forKey: "block.order") == ["rename", "shelf", "nowplaying", "hello", "gone"])
}

@Test func installSheetListsAccessAndSigner() {
    let signed = BlockPackageSummary(id: "hello", name: "Hello", version: "1.0", contract: 2,
                                     permissions: ["Old free text"], sourcePath: "/tmp/Hello.topblock",
                                     access: ["Use the network", "Read files you choose"],
                                     signer: "Jane Developer")
    let signedText = InstallSheetText(signed)
    #expect(signedText.access == "Use the network\nRead files you choose")
    #expect(signedText.creator == "Jane Developer")
    #expect(signedText.creatorNote == nil)

    let unsigned = BlockPackageSummary(id: "hello", name: "Hello", version: "1.0", contract: 2,
                                       sourcePath: "/tmp/Hello.topblock")
    let unsignedText = InstallSheetText(unsigned)
    #expect(unsignedText.access == "Nothing")
    #expect(unsignedText.creator == "No signature: the creator cannot be verified")
}

// MARK: - Blocks page states

@MainActor
@Test func aRunningBlockShowsItsUsage() {
    let running = InfoBlock("shelf", info: BlockInfo(), usage: BlockUsage(memoryBytes: 38 * 1024 * 1024, processorFraction: 0.001))
    #expect(BlockEntry(block: running, installer: nil).usageLine == "38 MB · 0.1% processor")

    let busy = InfoBlock("busy", info: BlockInfo(), usage: BlockUsage(memoryBytes: 38 * 1024 * 1024, processorFraction: 1.25))
    #expect(BlockEntry(block: busy, installer: nil).usageLine == "38 MB · 125.0% processor")

    let idle = InfoBlock("idle", info: BlockInfo())
    #expect(BlockEntry(block: idle, installer: nil).usageLine == nil)
}

@MainActor
@Test func aNewBlockShowsReviewAndNoSwitch() {
    let home = "/Users/test"
    let path = "/Users/test/Library/Application Support/TopNotch/Blocks/Weather Peek.topblock"
    let block = InfoBlock("weather", info: BlockInfo(version: "1.2.0", source: .installed(from: path)),
                          health: .turnedOff(reason: "New: review this block before it runs."), review: .new)
    let installer = FakeInstaller(removable: ["weather"], cannotRun: ["weather"])

    let entry = BlockEntry(block: block, installer: installer, home: home)

    #expect(entry.badge == "New")
    #expect(entry.reviewText == "Found in the Blocks folder. Review it before it can run.")
    #expect(entry.offersReview)
    #expect(entry.isRemovable)
    #expect(!entry.hasSwitch)
    #expect(!entry.hasOrderControls)
    #expect(entry.turnedOffReason == nil, "the review text says why, not a stopped box")
    #expect(!entry.offersTurnOn)
    #expect(entry.detail == "~/Library/Application Support/TopNotch/Blocks/Weather Peek.topblock · 1.2.0 · Off")
    #expect(entry.accessibilityLabel == "Weather, New")

    let running = BlockEntry(block: InfoBlock("shelf", info: BlockInfo()), installer: installer)
    #expect(running.badge == nil)
    #expect(!running.offersReview)
    #expect(running.hasSwitch)
    #expect(running.hasOrderControls)
    #expect(running.accessibilityLabel == "Shelf")
    #expect(!BlockEntry(block: block, installer: nil).offersReview, "nothing to review with without an installer")
}

@MainActor
@Test func aChangedBlockShowsReviewAgain() {
    let block = InfoBlock("share", info: BlockInfo(source: .installed(from: "/tmp/Share.topblock")),
                          health: .turnedOff(reason: "Changed"), review: .changed)

    let entry = BlockEntry(block: block, installer: FakeInstaller(removable: ["share"]))

    #expect(entry.badge == "Changed")
    #expect(entry.reviewText == "This package changed since you approved it.")
    #expect(entry.offersReview)
    #expect(!entry.hasSwitch)
    #expect(entry.accessibilityLabel == "Share, Changed")
}

@MainActor
@Test func aBlockAwaitingReviewIsNotInTheSidebar() {
    let entries = [
        BlockEntry(block: InfoBlock("shelf", info: BlockInfo()), installer: nil),
        BlockEntry(block: InfoBlock("weather", info: BlockInfo(), review: .new), installer: nil),
        BlockEntry(block: InfoBlock("share", info: BlockInfo(), review: .changed), installer: nil),
        BlockEntry(block: InfoBlock("clock", info: BlockInfo(), health: .turnedOff(reason: "Stopped.")), installer: nil),
    ]

    #expect(BlockEntry.sidebar(entries).map(\.id) == ["shelf", "clock"])
}

@MainActor
@Test func aStoppedBlockShowsItsReasonWithTurnOn() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults, domain: name)
    let runtime = NotchRuntime()
    let reason = "It was stopped because it used more than 500 MB of memory."
    let block = InfoBlock("clock", info: BlockInfo())
    runtime.register(block)
    // As the app's turn-off closure does.
    settings.setEnabled("clock", false, in: runtime)
    block.health = .turnedOff(reason: reason)

    let entry = BlockEntry(block: block, installer: nil)
    #expect(entry.turnedOffReason == reason)
    #expect(entry.offersTurnOn)

    entry.turnOn(settings: settings, runtime: runtime)

    #expect(runtime.isEnabled("clock"))
    #expect(settings.isEnabled("clock"))
    let after = BlockEntry(block: block, installer: nil)
    #expect(after.turnedOffReason == nil, "Turn On clears the reason")
    #expect(!after.offersTurnOn)
}

@MainActor
@Test func aNoticeIsShownWithoutStoppingTheBlock() {
    let block = InfoBlock("weather", info: BlockInfo(), notice: "Weather started without network: no port")
    let entry = BlockEntry(block: block, installer: nil)
    #expect(entry.notice == "Weather started without network: no port")
    #expect(entry.turnedOffReason == nil)
    #expect(entry.hasSwitch)
}

@Test func theFooterSaysWhereBlocksLive() {
    #expect(BlockEntry.blocksFolderNote == "Blocks live in ~/Library/Application Support/TopNotch/Blocks")
}

@MainActor
@Test func removingABlockRemovesItFromTheOrder() {
    let (defaults, name) = makeDefaults()
    defer { cleanUp(defaults, name) }
    let settings = BlockSettings(defaults: defaults, domain: name)
    settings.setOrder(["shelf", "hello", "nowplaying", "rename"])

    settings.clear("hello")

    #expect(defaults.stringArray(forKey: "block.order") == ["shelf", "nowplaying", "rename"])
    #expect(settings.order == ["shelf", "nowplaying", "rename"])
}
