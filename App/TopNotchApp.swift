import AppKit
import DemoBlock
import EventSources
import NotchCore
import NotchShell
import PlatformServices
import RenameBlock
import ShelfBlock
import SwiftUI

/// Thin app target. It only starts the process and wires the modules together;
/// all behaviour lives in the NotchKit package modules.
@main
struct TopNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("TopNotch", systemImage: "rectangle.topthird.inset.filled") {
            MenuBarContent(runtime: delegate.runtime)
        }
        Settings {
            SettingsRootView(runtime: delegate.runtime, settings: delegate.settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = NotchRuntime()
    let settings = BlockSettings()
    private let onboarding = OnboardingController()
    private var shell: NotchShellController?
    private var dragMonitor: DragMonitor?
    private var screenshotWatcher: ScreenshotWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        var blocks: [any NotchBlock] = [ShelfBlock(), RenameBlock()]
        // `-demoBlock YES` adds the demo block, to try hover, click and drop.
        if defaults.bool(forKey: "demoBlock") { blocks.append(DemoBlock()) }
        for block in blocks {
            runtime.register(block, enabled: settings.isEnabled(block.id))
        }

        // `-forcePill YES` tries the floating pill on a Mac with a notch.
        let shell = NotchShellController(runtime: runtime, forcePill: defaults.bool(forKey: "forcePill"))
        shell.start()
        self.shell = shell

        let dragMonitor = DragMonitor(runtime: runtime)
        dragMonitor.start()
        self.dragMonitor = dragMonitor

        let screenshotWatcher = ScreenshotWatcher(runtime: runtime)
        screenshotWatcher.start()
        self.screenshotWatcher = screenshotWatcher

        onboarding.showIfNeeded()
    }
}
