import AppKit
import NotchCore
import os

/// Publishes `NowPlayingChanged` for a player that announces its state with a
/// distributed notification: Spotify and Music. Needs no permission (measured
/// for Spotify in the pd-1 check). Both put the state in the key
/// "Player State" and the track in "Name", "Artist" and "Album".
///
/// This is the documented, dependable source for these two players.
/// `SystemNowPlayingWatcher` covers every other player, and adds artwork.
///
/// Limits:
/// - A player posts only on a change, so after TopNotch starts the track is
///   known from the next play, pause or track change.
/// - No artwork in the notification.
@MainActor
public final class PlayerNotificationWatcher {
    public struct Player: Sendable {
        public let name: String
        let notification: Notification.Name
        let bundleID: String

        public static let spotify = Player(
            name: "Spotify", notification: .init("com.spotify.client.PlaybackStateChanged"), bundleID: "com.spotify.client"
        )
        /// The name matches the app's own, as `SystemNowPlayingWatcher` reports it.
        public static let music = Player(
            name: "Music", notification: .init("com.apple.Music.playerInfo"), bundleID: "com.apple.Music"
        )
    }

    private let runtime: NotchRuntime
    private let player: Player
    private(set) var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "nowplaying")

    public init(runtime: NotchRuntime, player: Player) {
        self.runtime = runtime
        self.player = player
    }

    public func start() {
        guard observers.isEmpty else { return }
        let player = self.player
        let distributed = DistributedNotificationCenter.default()
        let changed = distributed.addObserver(forName: player.notification, object: nil, queue: .main) { [weak self] note in
            let event = Self.event(from: note.userInfo ?? [:], player: player.name)
            MainActor.assumeIsolated { self?.publish(event) }
        }
        observers.append((distributed, changed))
        // A player does not always post "Stopped" when it quits.
        let workspace = NSWorkspace.shared.notificationCenter
        let quit = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == player.bundleID else { return }
            MainActor.assumeIsolated { self?.publish(NowPlayingChanged(player: player.name, state: .stopped)) }
        }
        observers.append((workspace, quit))
        log.info("watching \(player.name, privacy: .public)")
    }

    public func stop() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
    }

    private func publish(_ event: NowPlayingChanged?) {
        guard let event else { return }
        runtime.publish(event)
    }

    /// The event for one notification, or nil when it has no state.
    nonisolated static func event(from info: [AnyHashable: Any], player: String) -> NowPlayingChanged? {
        let state: NowPlayingChanged.State
        switch info["Player State"] as? String {
        case "Playing": state = .playing
        case "Paused": state = .paused
        case "Stopped": state = .stopped
        default: return nil
        }
        return NowPlayingChanged(
            player: player,
            state: state,
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? ""
        )
    }
}
