import AppKit
import NotchCore
import SwiftUI

/// Owns the Settings window.
///
/// The app opens it from AppKit (the notch menu) as well as from SwiftUI (the
/// menu bar item). SwiftUI's own Settings scene can only be opened from inside
/// a SwiftUI view, so the window is managed here instead.
@MainActor
public final class SettingsWindowController {
    private let runtime: NotchRuntime
    private let settings: BlockSettings
    private let installer: (any BlockInstalling)?
    private let consent: ScreenshotFolderConsent?
    private var window: NSWindow?

    /// - Parameters:
    ///   - installer: installs, updates and removes blocks from the
    ///     Blocks page. Nil hides those buttons.
    ///   - consent: the screenshot folder answer: updated by "Allow access"
    ///     on the General page, and read by the Blocks page to say why a
    ///     block that needs the folder does nothing.
    public init(runtime: NotchRuntime, settings: BlockSettings, installer: (any BlockInstalling)? = nil,
                consent: ScreenshotFolderConsent? = nil) {
        self.runtime = runtime
        self.settings = settings
        self.installer = installer
        self.consent = consent
    }

    public func show() {
        // The app has no Dock icon; without activating, the window opens behind others.
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: SettingsRootView(runtime: runtime, settings: settings, installer: installer,
                                                               consent: consent))
        // The window keeps the size it is given; see OnboardingController.show.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.title = "TopNotch Settings"
        // Kept after closing, so it reopens on the pane and at the place it was left.
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
