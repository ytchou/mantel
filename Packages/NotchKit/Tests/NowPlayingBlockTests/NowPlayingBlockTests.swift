import Foundation
import NotchCore
import Testing
@testable import NowPlayingBlock

/// A fresh defaults suite, so tests never read the user's own settings.
private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "NowPlayingBlockTests.\(UUID().uuidString)")!
}

@MainActor
private func makeBlock(defaults: UserDefaults = makeDefaults()) -> (NotchRuntime, NowPlayingBlock) {
    let runtime = NotchRuntime()
    let block = NowPlayingBlock(defaults: defaults)
    runtime.register(block)
    return (runtime, block)
}

private func play(_ title: String, by artist: String = "Singer", in player: String = "Spotify", artwork: Data? = nil) -> NowPlayingChanged {
    NowPlayingChanged(player: player, state: .playing, title: title, artist: artist, artwork: artwork)
}

private let volume = OutputVolumeChanged(volume: 0.5, isMuted: false)

// MARK: Volume

@MainActor
@Test func aVolumeChangeWhileSomethingPlaysShowsTheTrackBriefly() {
    let (runtime, block) = makeBlock()
    runtime.publish(play("Song"))
    let trackShown = runtime.state.presentation?.id

    runtime.publish(volume)
    #expect(runtime.state.owner == "nowplaying")
    #expect(runtime.state.presentation?.id != trackShown)
    #expect(runtime.state.level == .peek)
    #expect(runtime.state.presentation?.duration == NowPlayingBlock.duration)
    #expect(runtime.state.presentation?.priority == .standard)
    #expect(block.model.track?.title == "Song")
    #expect(block.model.volume == 0.5)
}

@MainActor
@Test func nothingShowsWhenNothingPlays() {
    let (runtime, _) = makeBlock()
    // No player running: no track was ever reported.
    runtime.publish(volume)
    #expect(runtime.state.owner == nil)

    for state in [NowPlayingChanged.State.paused, .stopped] {
        runtime.publish(play("Song"))
        runtime.publish(NowPlayingChanged(player: "Spotify", state: state, title: "Song", artist: "Singer"))
        #expect(runtime.state.owner == nil)
        runtime.publish(volume)
        #expect(runtime.state.owner == nil)
    }
}

@MainActor
@Test func theVolumeSettingTurnsTheVolumeTriggerOff() {
    let defaults = makeDefaults()
    defaults.set("NO", forKey: NowPlayingSettings.showOnVolumeChangeKey)
    defaults.set("NO", forKey: NowPlayingSettings.showOnTrackChangeKey)
    let (runtime, block) = makeBlock(defaults: defaults)
    runtime.publish(play("Song"))
    #expect(block.model.track?.title == "Song")
    runtime.publish(volume)
    #expect(runtime.state.owner == nil)
}

// MARK: Track changes

@MainActor
@Test func aNewTrackShowsItself() {
    let (runtime, block) = makeBlock()
    runtime.publish(play("First"))
    #expect(runtime.state.owner == "nowplaying")
    // No volume change yet: the volume is unknown, and the view leaves out its bar.
    #expect(block.model.volume == nil)
    #expect(runtime.state.presentation?.duration == NowPlayingBlock.duration)

    // Next, back, or the song ending on its own: each is a new track event.
    let shown = runtime.state.presentation?.id
    runtime.publish(play("Second"))
    #expect(block.model.track?.title == "Second")
    #expect(runtime.state.presentation?.id != shown)
}

@MainActor
@Test func pausingAndPlayingTheSameSongIsNotANewTrack() {
    let (runtime, _) = makeBlock()
    runtime.publish(play("Song"))
    runtime.publish(NowPlayingChanged(player: "Spotify", state: .paused, title: "Song", artist: "Singer"))
    #expect(runtime.state.owner == nil)

    runtime.publish(play("Song"))
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func theSameSongFromTwoSourcesShowsOnceAndKeepsTheArtwork() {
    let (runtime, block) = makeBlock()
    let art = Data([1, 2, 3])
    runtime.publish(play("Song"))
    let shown = runtime.state.presentation?.id
    // The system source reports the same song, with artwork.
    runtime.publish(play("Song", artwork: art))
    #expect(runtime.state.presentation?.id == shown)
    #expect(block.model.track?.artwork == art)
    // The player's own source again, without artwork: the artwork stays.
    runtime.publish(play("Song"))
    #expect(block.model.track?.artwork == art)
}

@MainActor
@Test func theTrackSettingTurnsTheTrackTriggerOff() {
    let defaults = makeDefaults()
    defaults.set(false, forKey: NowPlayingSettings.showOnTrackChangeKey)
    let (runtime, block) = makeBlock(defaults: defaults)
    runtime.publish(play("Song"))
    #expect(runtime.state.owner == nil)
    #expect(block.model.track?.title == "Song")
    // The volume trigger still works.
    runtime.publish(volume)
    #expect(runtime.state.owner == "nowplaying")
}

// MARK: Several players

@MainActor
@Test func theLastPlayerToStartIsShownAndAPauseElsewhereKeepsIt() {
    let (runtime, block) = makeBlock()
    runtime.publish(play("Song"))
    runtime.publish(play("Video", by: "Channel", in: "Google Chrome"))
    #expect(block.model.track?.player == "Google Chrome")

    // Spotify pauses: the video is still playing and still shown.
    runtime.publish(NowPlayingChanged(player: "Spotify", state: .paused))
    #expect(block.model.track?.title == "Video")
    #expect(runtime.state.owner == "nowplaying")

    // The video stops too: nothing plays, nothing shows.
    runtime.publish(NowPlayingChanged(player: "Google Chrome", state: .stopped))
    #expect(block.model.track == nil)
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func whenTheShownPlayerStopsTheOtherOneIsShownWithoutPopping() {
    let (runtime, block) = makeBlock()
    runtime.publish(play("Song"))
    runtime.publish(play("Video", by: "Channel", in: "Google Chrome"))
    let shown = runtime.state.presentation?.id

    runtime.publish(NowPlayingChanged(player: "Google Chrome", state: .paused))
    #expect(block.model.track?.title == "Song")
    // Not a new track: no new presentation; the one on screen updates in place.
    #expect(runtime.state.presentation?.id == shown)
    runtime.publish(volume)
    #expect(runtime.state.presentation?.id != shown)
}

// MARK: Block

@MainActor
@Test func turningTheBlockOffForgetsTheTrack() {
    let (runtime, block) = makeBlock()
    runtime.publish(play("Song"))
    runtime.setEnabled("nowplaying", false)
    runtime.setEnabled("nowplaying", true)
    runtime.publish(volume)
    #expect(block.model.track == nil)
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func theBlockDescribesItselfAndHasSettings() {
    let block = NowPlayingBlock(defaults: makeDefaults())
    #expect(!block.info.summary.isEmpty)
    #expect(block.info.permissions.isEmpty)
    #expect(block.settingsPane != nil)
    #expect(block.settings.showOnVolumeChange)
    #expect(block.settings.showOnTrackChange)
}
