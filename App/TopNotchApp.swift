import AppKit
import BlockHost
import EventSources
import NotchCore
import NotchShell
import PlatformServices
import SwiftUI

/// Thin app target. It only starts the process and wires the modules together;
/// all behaviour lives in the NotchKit package modules.
@main
struct TopNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("TopNotch", systemImage: "rectangle.topthird.inset.filled") {
            MenuBarContent(runtime: delegate.runtime) { delegate.settingsWindow.show() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = NotchRuntime()
    let settings = BlockSettings()
    private(set) lazy var settingsWindow = SettingsWindowController(runtime: runtime, settings: settings, installer: blockStore)
    private lazy var notchMenu = NotchMenu(runtime: runtime) { [weak self] in self?.settingsWindow.show() }
    private let onboarding = OnboardingController()
    private lazy var blockStore = BlockStore(
        owner: { [runtime] in runtime.state.owner },
        blocksRoot: BlockStore.defaultBlocksRoot,
        dataRoot: BlockStore.defaultDataRoot,
        // Built into Contents/Resources/Blocks by the "Build bundled blocks" phase.
        bundledRoot: Bundle.main.resourceURL?.appending(path: "Blocks"),
        // The folder `files.screenshots` opens: the one the screenshot watcher reads.
        screenshotFolder: { ScreenshotFolder.current() },
        defaults: .standard,
        // A block that keeps failing is turned off the way the user would, so the Blocks page redraws.
        turnOff: { [settings, runtime] id in settings.setEnabled(id, false, in: runtime) },
        // A block installed from the Blocks page joins like one found at launch,
        // then takes its place in the stored order (a new id goes last).
        register: { [settings, runtime] block in
            runtime.register(block, enabled: settings.isEnabled(block.id))
            settings.applyOrder(to: runtime)
        },
        unregister: { [runtime] id in runtime.unregister(id) },
        clearKeys: { [settings] id in settings.clear(id) },
        // A package whose id the runtime already has is refused, as the runtime would drop it.
        isRegistered: { [runtime] id in runtime.blocks.contains { $0.id == id } }
    )
    private var shell: NotchShellController?
    private var sources: SourceCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        // The bundled blocks (Shelf, Now Playing, Screenshot Names), the
        // installed blocks, then, with `-devBlock <path to .topblock>`, one
        // block run from where it is. Every block runs in its own process.
        let blocks = blockStore.standIns(developmentPath: defaults.string(forKey: "devBlock"))
        for block in blocks {
            runtime.register(block, enabled: settings.isEnabled(block.id))
        }
        // The order the owner set on the Blocks page, or the default one.
        settings.applyOrder(to: runtime)

        // `-forcePill YES` tries the floating pill on a Mac with a notch.
        let shell = NotchShellController(runtime: runtime, forcePill: defaults.bool(forKey: "forcePill"))
        // Right-click on the notch: the menu bar item can be hidden behind the notch.
        shell.contextMenu = { [weak self] in self?.notchMenu.make() }
        shell.start()
        self.shell = shell

        // Each source runs only while an enabled block listens to its events.
        // Blocks are registered above, so the ones turned on start here.
        let sources = SourceCoordinator(runtime: runtime)
        sources.add(DragMonitor(runtime: runtime), for: [DragSessionStarted.self, DragSessionEnded.self])
        sources.add(ScreenshotWatcher(runtime: runtime), for: [ScreenshotCaptured.self])
        sources.add(OutputVolumeWatcher(runtime: runtime), for: [OutputVolumeChanged.self])
        for player in [PlayerNotificationWatcher.Player.spotify, .music] {
            sources.add(PlayerNotificationWatcher(runtime: runtime, player: player), for: [NowPlayingChanged.self])
        }
        // Built into Contents/Frameworks by the "Build now-playing helper" phase.
        let helper = Bundle.main.privateFrameworksURL?.appending(path: "TopNotchNowPlaying.dylib")
        sources.add(SystemNowPlayingWatcher(runtime: runtime, helperURL: helper), for: [NowPlayingChanged.self])
        self.sources = sources

        onboarding.showIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        blockStore.stopAll()
    }
}
