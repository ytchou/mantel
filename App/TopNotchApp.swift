import AppKit
import DemoBlock
import NotchCore
import NotchShell
import SwiftUI

/// Thin app target. It only starts the process and wires the modules together;
/// all behaviour lives in the NotchKit package modules.
@main
struct TopNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A background app needs one scene; the settings window is built in phase 3.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = NotchRuntime()
    private var shell: NotchShellController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.register(DemoBlock())
        let shell = NotchShellController(runtime: runtime)
        shell.start()
        self.shell = shell
    }
}
