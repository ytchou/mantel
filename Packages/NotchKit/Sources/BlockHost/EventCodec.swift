import BlockWire
import Foundation
import NotchCore

/// Why an event name was refused.
public enum EventCodecError: Error, Equatable, Sendable {
    /// The name is not one of `WireEvent`'s.
    case unknownEvent(String)
}

/// Translates the app's `NotchEvent` values to wire events, by name.
///
/// This is the list of events a block in its own process can hear. A new
/// `NotchEvent` that blocks should hear needs a case in `WireEvent`, a branch
/// in `payload(for:)` and one in `subscribe`.
@MainActor
enum EventCodec {
    /// Artwork larger than this is left out of a `nowPlaying` event, so one
    /// track change never comes near the frame limit.
    nonisolated static let maxArtworkBytes = 1024 * 1024

    /// The wire event for a manifest's event name.
    nonisolated static func wireEvent(named name: String) throws(EventCodecError) -> WireEvent {
        guard let event = WireEvent(rawValue: name) else { throw .unknownEvent(name) }
        return event
    }

    /// The wire payload for an event, or nil for an event blocks cannot hear.
    nonisolated static func payload(for event: any NotchEvent) -> EventPayload? {
        switch event {
        case let event as PointerHoverChanged:
            return .pointerHover(PointerHover(isInside: event.isInside))
        case let event as OutputVolumeChanged:
            return .outputVolume(OutputVolume(volume: event.volume, isMuted: event.isMuted))
        case let event as NowPlayingChanged:
            let state: NowPlaying.State = switch event.state {
            case .playing: .playing
            case .paused: .paused
            case .stopped: .stopped
            }
            let artwork = event.artwork.flatMap { $0.count <= maxArtworkBytes ? $0 : nil }
            return .nowPlaying(NowPlaying(player: event.player, state: state, title: event.title,
                                          artist: event.artist, album: event.album, artwork: artwork))
        case let event as ScreenshotCaptured:
            return .screenshotCaptured(Screenshot(path: event.url.path, createdAt: event.createdAt.timeIntervalSince1970))
        case let event as DragSessionStarted:
            let kinds = event.kinds.map { kind -> DragStarted.Kind in
                switch kind {
                case .file: .file
                case .link: .link
                case .text: .text
                }
            }
            return .dragStarted(DragStarted(kinds: kinds.sorted { $0.rawValue < $1.rawValue }))
        case is DragSessionEnded:
            return .dragEnded
        default:
            return nil
        }
    }

    /// Subscribes `context` to the app event behind `name` and hands each
    /// one to `handler` as a wire payload.
    static func subscribe(
        _ name: WireEvent,
        in context: any BlockContext,
        _ handler: @escaping @MainActor (EventPayload) -> Void
    ) {
        func forward<E: NotchEvent>(_ type: E.Type) {
            context.subscribe(to: type) { event in
                if let payload = payload(for: event) { handler(payload) }
            }
        }
        switch name {
        case .pointerHover: forward(PointerHoverChanged.self)
        case .outputVolume: forward(OutputVolumeChanged.self)
        case .nowPlaying: forward(NowPlayingChanged.self)
        case .screenshotCaptured: forward(ScreenshotCaptured.self)
        case .dragStarted: forward(DragSessionStarted.self)
        case .dragEnded: forward(DragSessionEnded.self)
        }
    }
}
