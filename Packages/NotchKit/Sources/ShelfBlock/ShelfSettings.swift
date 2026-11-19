import Foundation
import Observation
import SwiftUI

/// The shelf's settings, stored in `UserDefaults` under keys prefixed `shelf.`.
@MainActor
@Observable
final class ShelfSettings {
    static let collectScreenshotsKey = "shelf.collectScreenshots"

    @ObservationIgnored private let defaults: UserDefaults

    /// Add each new screenshot to the shelf. On unless turned off.
    var collectScreenshots: Bool {
        didSet { defaults.set(collectScreenshots, forKey: Self.collectScreenshotsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)`, so a launch argument string such as "NO" counts.
        collectScreenshots = defaults.object(forKey: Self.collectScreenshotsKey) == nil
            || defaults.bool(forKey: Self.collectScreenshotsKey)
    }
}

/// The block's pane in the settings window.
struct ShelfSettingsView: View {
    @Bindable var settings: ShelfSettings

    var body: some View {
        Toggle("Add new screenshots to the shelf", isOn: $settings.collectScreenshots)
        Text("The screenshot stays in the folder macOS saves it to. The shelf holds it so you can drag it from the notch to where it belongs.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
