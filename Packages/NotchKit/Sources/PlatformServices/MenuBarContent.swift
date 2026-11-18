import AppKit
import NotchCore
import SwiftUI

/// Content of the menu bar item's menu: one section per enabled block that has
/// actions, then "Settings…", then "Quit TopNotch".
public struct MenuBarContent: View {
    private let runtime: NotchRuntime
    @Environment(\.openSettings) private var openSettings

    public init(runtime: NotchRuntime) {
        self.runtime = runtime
    }

    public var body: some View {
        let _ = EnablementSignal.shared.revision
        ForEach(sections) { section in
            Section(section.title) {
                ForEach(section.actions) { action in
                    Button(action.title) { action.perform() }
                        .disabled(!action.isEnabled)
                }
            }
        }
        Divider()
        Button("Settings…") {
            // The app has no Dock icon, so bring it forward or the window opens behind others.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit TopNotch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var sections: [MenuSection] {
        runtime.blocks.compactMap { block in
            guard runtime.isEnabled(block.id) else { return nil }
            let actions = block.actions
            return actions.isEmpty ? nil : MenuSection(id: block.id, title: block.title, actions: actions)
        }
    }
}

private struct MenuSection: Identifiable {
    let id: BlockID
    let title: String
    let actions: [BlockAction]
}
