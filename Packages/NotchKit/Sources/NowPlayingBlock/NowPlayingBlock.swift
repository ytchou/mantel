import NotchCore
import Observation
import SwiftUI

/// Shows what is playing when the volume changes: the track, the artist and
/// the new volume, for a few seconds.
///
/// Written against the block contract as it was before this block, to test
/// it: the block hears `NowPlayingChanged` and `OutputVolumeChanged` and
/// nothing else.
@MainActor
public final class NowPlayingBlock: NotchBlock {
    public let id: BlockID = "nowplaying"
    public let title = "Now Playing"
    public let info = BlockInfo(
        summary: "Shows the Spotify track and the volume when you change the volume.",
        symbol: "music.note",
        trigger: "Changing the volume while Spotify plays"
    )

    static let peekSize = CGSize(width: 340, height: 36)
    static let duration: Duration = .seconds(3)

    struct Track: Equatable {
        var title: String
        var artist: String
    }

    @MainActor
    @Observable
    final class Model {
        /// The playing track; nil while nothing plays.
        var track: Track?
        var volume: Double = 0
        var isMuted = false
    }

    let model = Model()
    private var context: (any BlockContext)?

    public init() {}

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
        model.track = nil
    }

    private func nowPlayingChanged(_ event: NowPlayingChanged) {
        guard event.state == .playing else {
            model.track = nil
            context?.dismiss()
            return
        }
        // Shown already: the view updates in place.
        model.track = Track(title: event.title, artist: event.artist)
    }

    private func volumeChanged(_ event: OutputVolumeChanged) {
        model.volume = event.volume
        model.isMuted = event.isMuted
        guard model.track != nil, let context else { return }
        let model = self.model
        context.present(Presentation(
            priority: .standard,
            peek: NotchContent(size: Self.peekSize) { NowPlayingPeekView(model: model) },
            duration: Self.duration
        ))
        // It answers a volume change. Shown later, after a drag or while the
        // pointer was on the shelf, it would answer nothing, so it does not wait.
        if !context.ownsNotch { context.dismiss() }
    }
}

struct NowPlayingPeekView: View {
    let model: NowPlayingBlock.Model

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.15))
                .frame(width: 24, height: 24)
                .overlay(Image(systemName: "music.note").font(.system(size: 11)).opacity(0.8))
            VStack(alignment: .leading, spacing: 0) {
                Text(model.track?.title ?? "")
                    .font(.system(size: 12, weight: .medium))
                Text(model.track?.artist ?? "")
                    .font(.system(size: 10))
                    .opacity(0.7)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10))
                .opacity(0.8)
                .frame(width: 16)
            Capsule()
                .fill(.white.opacity(0.2))
                .frame(width: 60, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: 60 * (model.isMuted ? 0 : model.volume), height: 4)
                }
                .accessibilityLabel(model.isMuted ? "Muted" : "Volume \(Int((model.volume * 100).rounded())) percent")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }
}
