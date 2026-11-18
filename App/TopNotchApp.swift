import NotchCore
import SwiftUI

/// Thin app target. It only starts the process; all behaviour lives in the
/// NotchKit package modules.
@main
struct TopNotchApp: App {
    var body: some Scene {
        // A background app needs one scene; the settings window is built in phase 3.
        Settings {
            EmptyView()
        }
    }
}
