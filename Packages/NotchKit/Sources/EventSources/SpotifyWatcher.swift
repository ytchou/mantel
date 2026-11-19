import AppKit
import NotchCore
import os

/// Publishes `NowPlayingChanged` for Spotify. Needs no permission: Spotify
/// posts a distributed notification on every play, pause, stop and track
/// change, with the track in its user info (measured in the pd-1 check).
///
/// Limits:
/// - Spotify posts only on a change, so after TopNotch starts the track is
///   known from the next play, pause or track change. Asking Spotify for the
///   current track needs AppleScript, which needs the Automation permission.
/// - The notification has no artwork, only a "Has Artwork" flag.
@MainActor
public final class SpotifyWatcher {
    static let notification = Notification.Name("com.spotify.client.PlaybackStateChanged")
    static let bundleID = "com.spotify.client"

    private let runtime: NotchRuntime
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "nowplaying")

    public init(runtime: NotchRuntime) {
        self.runtime = runtime
    }

    public func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let changed = distributed.addObserver(forName: Self.notification, object: nil, queue: .main) { [weak self] note in
            let event = Self.event(from: note.userInfo ?? [:])
            MainActor.assumeIsolated { self?.publish(event) }
        }
        observers.append((distributed, changed))
        // Spotify does not always post "Stopped" when it quits.
        let workspace = NSWorkspace.shared.notificationCenter
        let quit = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated { self?.publish(NowPlayingChanged(player: "Spotify", state: .stopped)) }
        }
        observers.append((workspace, quit))
        log.info("watching Spotify")
    }

    public func stop() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
    }

    private func publish(_ event: NowPlayingChanged?) {
        guard let event else { return }
        runtime.publish(event)
    }

    /// The event for one Spotify notification, or nil when it has no state.
    nonisolated static func event(from info: [AnyHashable: Any]) -> NowPlayingChanged? {
        let state: NowPlayingChanged.State
        switch info["Player State"] as? String {
        case "Playing": state = .playing
        case "Paused": state = .paused
        case "Stopped": state = .stopped
        default: return nil
        }
        return NowPlayingChanged(
            player: "Spotify",
            state: state,
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? ""
        )
    }
}
