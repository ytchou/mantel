import AppKit
import NotchCore
import Observation
import SwiftUI

/// Shows what is playing, for a few seconds, when the volume changes or a new
/// track starts: the track, the artist, the artwork when there is one, and
/// the volume.
///
/// Written against the block contract as it was before this block, to test
/// it: the block hears `NowPlayingChanged` and `OutputVolumeChanged` and
/// nothing else. Several players can report at once (Spotify, a browser);
/// the one that started playing last is shown.
@MainActor
public final class NowPlayingBlock: NotchBlock {
    public let id: BlockID = "nowplaying"
    public let title = "Now Playing"
    public let info = BlockInfo(
        summary: "Shows what is playing, in Spotify, Music, YouTube and more, when the volume or the track changes.",
        symbol: "music.note",
        trigger: "Changing the volume, or a new track starting"
    )

    static let peekSize = CGSize(width: 380, height: 52)
    static let duration: Duration = .seconds(3)

    struct Track: Equatable {
        var player: String
        var title: String
        var artist: String
        var artwork: Data?

        /// The same song in the same player, whatever the artwork.
        func isSameSong(as other: Track?) -> Bool {
            guard let other else { return false }
            return player == other.player && title == other.title && artist == other.artist
        }
    }

    @MainActor
    @Observable
    final class Model {
        /// The track shown: the one that started playing last. Nil while nothing plays.
        var track: Track?
        /// Nil until the first volume change: the block only learns it from events.
        var volume: Double?
        var isMuted = false
    }

    let model = Model()
    let settings: NowPlayingSettings
    private var context: (any BlockContext)?
    /// Each player's current track, while it plays.
    private var playing: [String: Track] = [:]
    /// Players in the order they started playing; the last one is shown.
    private var order: [String] = []
    /// The last song this block showed for a track change. A pause and play
    /// of the same song is not a new track.
    private var lastSong: Track?

    public convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        settings = NowPlayingSettings(defaults: defaults)
    }

    public func activate(_ context: any BlockContext) {
        self.context = context
        context.subscribe(to: NowPlayingChanged.self) { [weak self] event in
            self?.nowPlayingChanged(event)
        }
        context.subscribe(to: OutputVolumeChanged.self) { [weak self] event in
            self?.volumeChanged(event)
        }
    }

    public func deactivate() {
        context = nil
        playing = [:]
        order = []
        lastSong = nil
        model.track = nil
    }

    public var settingsPane: AnyView? {
        AnyView(NowPlayingSettingsView(settings: settings))
    }

    // MARK: Events

    private func nowPlayingChanged(_ event: NowPlayingChanged) {
        order.removeAll { $0 == event.player }
        if event.state == .playing {
            var track = Track(player: event.player, title: event.title, artist: event.artist, artwork: event.artwork)
            // Another source may have sent the artwork for this song already.
            if track.artwork == nil, let known = playing[event.player], known.isSameSong(as: track) {
                track.artwork = known.artwork
            }
            playing[event.player] = track
            order.append(event.player)
        } else {
            playing[event.player] = nil
        }
        model.track = order.last.flatMap { playing[$0] }

        guard let track = model.track else {
            context?.dismiss()
            return
        }
        // Shown already: the view updates in place.
        if track.player == event.player, event.state == .playing, !track.isSameSong(as: lastSong) {
            lastSong = track
            if settings.showOnTrackChange { show() }
        }
    }

    private func volumeChanged(_ event: OutputVolumeChanged) {
        model.volume = event.volume
        model.isMuted = event.isMuted
        guard model.track != nil, settings.showOnVolumeChange else { return }
        show()
    }

    private func show() {
        guard let context else { return }
        let model = self.model
        context.present(Presentation(
            priority: .standard,
            peek: NotchContent(size: Self.peekSize) { NowPlayingPeekView(model: model) },
            duration: Self.duration
        ))
        // It answers a change just made. Shown later, after a drag or while
        // the pointer was on the shelf, it would answer nothing, so it does not wait.
        if !context.ownsNotch { context.dismiss() }
    }
}

struct NowPlayingPeekView: View {
    let model: NowPlayingBlock.Model

    var body: some View {
        HStack(spacing: NotchStyle.spacing) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(model.track?.title ?? "")
                    .font(NotchStyle.title)
                Text(subtitle)
                    .font(NotchStyle.secondary)
                    .opacity(NotchStyle.secondaryOpacity)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 4)
            if let volume = model.volume {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .opacity(0.8)
                    .frame(width: 18)
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(width: 64, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: 64 * (model.isMuted ? 0 : volume), height: 5)
                    }
                    .accessibilityLabel(model.isMuted ? "Muted" : "Volume \(Int((volume * 100).rounded())) percent")
            }
        }
        .padding(.horizontal, NotchStyle.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    /// The artist, or the player when there is none (a video often has none).
    private var subtitle: String {
        guard let track = model.track else { return "" }
        return track.artist.isEmpty ? track.player : track.artist
    }

    @ViewBuilder private var artwork: some View {
        let side = NotchStyle.leadingImageSize
        let corner = RoundedRectangle(cornerRadius: NotchStyle.leadingImageRadius, style: .continuous)
        if let data = model.track?.artwork, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(corner)
        } else {
            corner
                .fill(.white.opacity(0.12))
                .frame(width: side, height: side)
                .overlay(Image(systemName: "music.note").font(.system(size: 15)).opacity(0.8))
        }
    }
}
