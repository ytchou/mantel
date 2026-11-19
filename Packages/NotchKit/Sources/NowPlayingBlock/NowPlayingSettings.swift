import Foundation
import Observation
import SwiftUI

/// The block's settings, stored in `UserDefaults` under keys prefixed `nowplaying.`.
@MainActor
@Observable
final class NowPlayingSettings {
    static let showOnVolumeChangeKey = "nowplaying.showOnVolumeChange"
    static let showOnTrackChangeKey = "nowplaying.showOnTrackChange"

    @ObservationIgnored private let defaults: UserDefaults

    var showOnVolumeChange: Bool {
        didSet { defaults.set(showOnVolumeChange, forKey: Self.showOnVolumeChangeKey) }
    }

    var showOnTrackChange: Bool {
        didSet { defaults.set(showOnTrackChange, forKey: Self.showOnTrackChangeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // On unless turned off. `bool(forKey:)`, so a launch argument such as "NO" counts.
        showOnVolumeChange = defaults.object(forKey: Self.showOnVolumeChangeKey) == nil
            || defaults.bool(forKey: Self.showOnVolumeChangeKey)
        showOnTrackChange = defaults.object(forKey: Self.showOnTrackChangeKey) == nil
            || defaults.bool(forKey: Self.showOnTrackChangeKey)
    }
}

/// The block's pane in the settings window.
struct NowPlayingSettingsView: View {
    @Bindable var settings: NowPlayingSettings

    var body: some View {
        Toggle("Show when the volume changes", isOn: $settings.showOnVolumeChange)
        Toggle("Show when a new track starts", isOn: $settings.showOnTrackChange)
        Text("Spotify and Music tell TopNotch about each track themselves. Other players, such as YouTube in a browser, are read from what macOS shows as Now Playing. That part of macOS is not documented by Apple, so it may stop working after a macOS update; Spotify and Music would still work.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
