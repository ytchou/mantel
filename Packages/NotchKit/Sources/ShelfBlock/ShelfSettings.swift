import Foundation
import Observation
import SwiftUI

/// The shelf's settings, stored in `UserDefaults` under keys prefixed `shelf.`.
@MainActor
@Observable
final class ShelfSettings {
    static let collectScreenshotsKey = "shelf.collectScreenshots"
    static let showCountKey = "shelf.showCount"

    @ObservationIgnored private let defaults: UserDefaults

    /// Add each new screenshot to the shelf. On unless turned off.
    var collectScreenshots: Bool {
        didSet { defaults.set(collectScreenshots, forKey: Self.collectScreenshotsKey) }
    }

    /// Show the item count beside the notch while the shelf holds items.
    /// Off unless turned on: the count covers a little of the menu bar, and
    /// with it off the notch looks untouched until the pointer is on it.
    var showCount: Bool {
        didSet {
            defaults.set(showCount, forKey: Self.showCountKey)
            onChange?()
        }
    }

    /// Called when a setting that changes what the notch shows was changed.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showCount = defaults.bool(forKey: Self.showCountKey)
        // `bool(forKey:)`, so a launch argument string such as "NO" counts.
        collectScreenshots = defaults.object(forKey: Self.collectScreenshotsKey) == nil
            || defaults.bool(forKey: Self.collectScreenshotsKey)
    }
}

/// The block's pane in the settings window.
struct ShelfSettingsView: View {
    @Bindable var settings: ShelfSettings

    var body: some View {
        Toggle("Show the item count beside the notch", isOn: $settings.showCount)
        Text("Off: the notch looks untouched while the shelf holds items; move the pointer onto it to open the shelf. On: a small count sits in the menu bar, left of the notch.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Toggle("Add new screenshots to the shelf", isOn: $settings.collectScreenshots)
        Text("The screenshot stays in the folder macOS saves it to. The shelf holds it so you can drag it from the notch to where it belongs.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
