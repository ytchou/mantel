import AppKit
import NotchCore

/// One block's commands, as shown in the menu bar menu and the notch menu.
struct MenuSection: Identifiable {
    let id: BlockID
    let title: String
    let actions: [BlockAction]
}

/// One section per enabled block that has actions, in registration order.
@MainActor
func menuSections(for runtime: NotchRuntime) -> [MenuSection] {
    runtime.blocks.compactMap { block in
        guard runtime.isEnabled(block.id) else { return nil }
        let actions = block.actions
        return actions.isEmpty ? nil : MenuSection(id: block.id, title: block.title, actions: actions)
    }
}

/// The menu shown on a right-click on the notch: the same commands as the menu
/// bar item. It exists because macOS hides the menu bar item behind the notch
/// when the menu bar is full, and the notch itself is always reachable.
@MainActor
public final class NotchMenu: NSObject {
    private let runtime: NotchRuntime
    private let openSettings: @MainActor () -> Void

    public init(runtime: NotchRuntime, openSettings: @escaping @MainActor () -> Void) {
        self.runtime = runtime
        self.openSettings = openSettings
    }

    /// A fresh menu, so titles and enabled states are current.
    public func make() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for section in menuSections(for: runtime) {
            menu.addItem(.sectionHeader(title: section.title))
            for action in section.actions {
                let item = item(action.title, action.perform)
                item.isEnabled = action.isEnabled
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(item("Settings\u{2026}", openSettings))
        menu.addItem(.separator())
        menu.addItem(item("Quit TopNotch") { NSApp.terminate(nil) })
        return menu
    }

    private func item(_ title: String, _ handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Handler(handler)
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        (sender.representedObject as? Handler)?.perform()
    }
}

/// Boxes a closure so a menu item can carry it.
@MainActor
private final class Handler {
    let perform: @MainActor () -> Void
    init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
}
