import AppKit
import NotchCore
import SwiftUI

/// Content of the menu bar item's menu: one section per enabled block that has
/// actions, then "Settings…", then "Quit TopNotch".
public struct MenuBarContent: View {
    private let runtime: NotchRuntime
    private let openSettings: @MainActor () -> Void

    public init(runtime: NotchRuntime, openSettings: @escaping @MainActor () -> Void) {
        self.runtime = runtime
        self.openSettings = openSettings
    }

    public var body: some View {
        let _ = EnablementSignal.shared.revision
        ForEach(menuSections(for: runtime)) { section in
            Section(section.title) {
                ForEach(section.actions) { action in
                    Button(action.title) { action.perform() }
                        .disabled(!action.isEnabled)
                }
            }
        }
        Divider()
        Button("Settings…") { openSettings() }
        .keyboardShortcut(",")
        Divider()
        Button("Quit TopNotch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
