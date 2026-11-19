import NotchCore
import Testing
@testable import EventSources

@Test func theVolumeFilterDropsRepeatsAndKeepsChanges() {
    var filter = VolumeChangeFilter(baseline: VolumeReading(volume: 0.44, isMuted: false))
    // Core Audio reports one change twice, with float noise.
    let first = filter.accept(VolumeReading(volume: 0.49999997, isMuted: false))
    let repeated = filter.accept(VolumeReading(volume: 0.5, isMuted: false))
    let muted = filter.accept(VolumeReading(volume: 0.5, isMuted: true))
    let back = filter.accept(VolumeReading(volume: 0.4399999, isMuted: false))
    #expect(first?.volume == 0.5)
    #expect(repeated == nil)
    #expect(muted?.isMuted == true)
    #expect(back?.volume == 0.44)
}

@Test func theBaselineIsNotAChange() {
    var filter = VolumeChangeFilter(baseline: VolumeReading(volume: 0.44, isMuted: false))
    let same = filter.accept(VolumeReading(volume: 0.44, isMuted: false))
    #expect(same == nil)
}

@Test func aSpotifyNotificationBecomesAnEvent() {
    // Keys as Spotify posted them in the pd-1 check.
    let info: [AnyHashable: Any] = [
        "Player State": "Playing", "Name": "Song", "Artist": "Singer", "Album": "Record",
        "Album Artist": "Singer", "Track ID": "spotify:track:1", "Has Artwork": true, "Duration": 200_000,
    ]
    let event = SpotifyWatcher.event(from: info)
    #expect(event?.state == .playing)
    #expect(event?.title == "Song")
    #expect(event?.artist == "Singer")
    #expect(event?.album == "Record")
    #expect(SpotifyWatcher.event(from: ["Player State": "Paused"])?.state == .paused)
    #expect(SpotifyWatcher.event(from: ["Player State": "Stopped"])?.state == .stopped)
    #expect(SpotifyWatcher.event(from: ["Name": "Song"]) == nil)
}
