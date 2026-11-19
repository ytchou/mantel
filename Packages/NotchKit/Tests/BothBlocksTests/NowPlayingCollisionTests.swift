import Foundation
import Testing
@testable import NotchCore
@testable import NowPlayingBlock
@testable import RenameBlock
@testable import ShelfBlock

// A volume change while the shelf or the rename block has the notch.
// All three blocks run in one runtime, as in the app.

@MainActor
private func spotifyPlays(_ f: Fixture) {
    f.runtime.publish(NowPlayingChanged(player: "Spotify", state: .playing, title: "Song", artist: "Singer"))
}

@MainActor
private func volumeChanges(_ f: Fixture) {
    f.runtime.publish(OutputVolumeChanged(volume: 0.5, isMuted: false))
}

@MainActor
@Test func aVolumeChangeDoesNotTakeTheNotchFromAShelfInUse() throws {
    let f = try Fixture()
    f.runtime.publish(DragSessionStarted(kinds: [.text]))
    f.runtime.send(.drop([.text("held")]))
    f.runtime.publish(DragSessionEnded())
    f.runtime.pointerHoverChanged(isInside: true)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    spotifyPlays(f)
    volumeChanges(f)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    // When the pointer leaves, the late volume change is not shown.
    f.runtime.pointerHoverChanged(isInside: false)
    #expect(f.runtime.state.owner == "shelf")
}

@MainActor
@Test func aVolumeChangeDuringADragLeavesTheDropTarget() throws {
    let f = try Fixture()
    spotifyPlays(f)
    f.runtime.publish(DragSessionStarted(kinds: [.file]))
    #expect(f.runtime.state.owner == "shelf")

    volumeChanges(f)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    // Nothing was dropped: the notch goes back to rest, not to a stale track.
    f.runtime.publish(DragSessionEnded())
    #expect(f.runtime.state.owner == nil)
}

@MainActor
@Test func aVolumeChangeDuringARenameResultShowsAndTheResultReturns() async throws {
    let f = try Fixture()
    spotifyPlays(f)
    f.capture(try makeScreenshot("Screenshot 1.png", in: f.folder))
    await waitUntil { if case .renamed = f.rename.model.phase { true } else { false } }
    #expect(f.runtime.state.owner == "rename")

    // Newest wins between two results: the volume change shows.
    volumeChanges(f)
    #expect(f.runtime.state.owner == "nowplaying")
    #expect(f.runtime.state.presentation?.duration == NowPlayingBlock.duration)

    // Its time runs out: the rename result is back, with its time.
    await waitUntil { f.clock.sleeperCount > 0 }
    f.clock.advance(by: NowPlayingBlock.duration)
    await waitUntil { f.runtime.state.owner == "rename" }
    #expect(f.runtime.state.owner == "rename")
    #expect(f.runtime.state.presentation?.duration == RenameBlock.resultDuration)
}
