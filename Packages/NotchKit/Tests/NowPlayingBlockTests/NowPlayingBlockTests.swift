import NotchCore
import Testing
@testable import NowPlayingBlock

@MainActor
private func makeBlock() -> (NotchRuntime, NowPlayingBlock) {
    let runtime = NotchRuntime()
    let block = NowPlayingBlock()
    runtime.register(block)
    return (runtime, block)
}

private let playing = NowPlayingChanged(player: "Spotify", state: .playing, title: "Song", artist: "Singer")

@MainActor
@Test func aVolumeChangeWhileSpotifyPlaysShowsTheTrackBriefly() {
    let (runtime, block) = makeBlock()
    runtime.publish(playing)
    #expect(runtime.state.owner == nil)

    runtime.publish(OutputVolumeChanged(volume: 0.5, isMuted: false))
    #expect(runtime.state.owner == "nowplaying")
    #expect(runtime.state.level == .peek)
    #expect(runtime.state.presentation?.duration == NowPlayingBlock.duration)
    #expect(runtime.state.presentation?.priority == .standard)
    #expect(block.model.track == NowPlayingBlock.Track(title: "Song", artist: "Singer"))
    #expect(block.model.volume == 0.5)
}

@MainActor
@Test func nothingShowsWhenNothingPlays() {
    let (runtime, _) = makeBlock()
    // Spotify not running: no track was ever reported.
    runtime.publish(OutputVolumeChanged(volume: 0.5, isMuted: false))
    #expect(runtime.state.owner == nil)

    for state in [NowPlayingChanged.State.paused, .stopped] {
        runtime.publish(playing)
        runtime.publish(NowPlayingChanged(player: "Spotify", state: state, title: "Song", artist: "Singer"))
        runtime.publish(OutputVolumeChanged(volume: 0.6, isMuted: false))
        #expect(runtime.state.owner == nil)
    }
}

@MainActor
@Test func pausingWhileShownRemovesIt() {
    let (runtime, _) = makeBlock()
    runtime.publish(playing)
    runtime.publish(OutputVolumeChanged(volume: 0.5, isMuted: true))
    #expect(runtime.state.owner == "nowplaying")

    runtime.publish(NowPlayingChanged(player: "Spotify", state: .paused))
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func aNewTrackUpdatesTheShownView() {
    let (runtime, block) = makeBlock()
    runtime.publish(playing)
    runtime.publish(OutputVolumeChanged(volume: 0.5, isMuted: false))
    let shown = runtime.state.presentation?.id

    runtime.publish(NowPlayingChanged(player: "Spotify", state: .playing, title: "Next", artist: "Other"))
    #expect(block.model.track?.title == "Next")
    // Same presentation; the view reads the model.
    #expect(runtime.state.presentation?.id == shown)
}

@MainActor
@Test func turningTheBlockOffForgetsTheTrack() {
    let (runtime, block) = makeBlock()
    runtime.publish(playing)
    runtime.setEnabled("nowplaying", false)
    runtime.setEnabled("nowplaying", true)
    runtime.publish(OutputVolumeChanged(volume: 0.5, isMuted: false))
    #expect(block.model.track == nil)
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func theBlockDescribesItselfAndNeedsNoPermission() {
    let block = NowPlayingBlock()
    #expect(!block.info.summary.isEmpty)
    #expect(block.info.permissions.isEmpty)
    #expect(block.settingsPane == nil)
}
