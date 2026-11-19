import Foundation
import NotchCore
import Testing
@testable import EventSources

// MARK: Volume

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

// MARK: Player notifications

@Test func aSpotifyNotificationBecomesAnEvent() {
    // Keys as Spotify posted them in the pd-1 check.
    let info: [AnyHashable: Any] = [
        "Player State": "Playing", "Name": "Song", "Artist": "Singer", "Album": "Record",
        "Album Artist": "Singer", "Track ID": "spotify:track:1", "Has Artwork": true, "Duration": 200_000,
    ]
    let event = PlayerNotificationWatcher.event(from: info, player: "Spotify")
    #expect(event?.player == "Spotify")
    #expect(event?.state == .playing)
    #expect(event?.title == "Song")
    #expect(event?.artist == "Singer")
    #expect(event?.album == "Record")
    #expect(event?.artwork == nil)
    #expect(PlayerNotificationWatcher.event(from: ["Player State": "Paused"], player: "Spotify")?.state == .paused)
    #expect(PlayerNotificationWatcher.event(from: ["Player State": "Stopped"], player: "Spotify")?.state == .stopped)
    #expect(PlayerNotificationWatcher.event(from: ["Name": "Song"], player: "Spotify") == nil)
}

@Test func theMusicAppUsesTheSameKeysUnderItsOwnName() {
    let player = PlayerNotificationWatcher.Player.music
    #expect(player.name == "Music")
    let event = PlayerNotificationWatcher.event(from: ["Player State": "Playing", "Name": "Tune", "Artist": "Band"], player: player.name)
    #expect(event?.player == "Music")
    #expect(event?.title == "Tune")
}

// MARK: System Now Playing

private func line(pid: Int32 = 10, playing: Bool = true, title: String? = "Video", artist: String? = "Channel", artwork: String? = nil) -> SystemNowPlayingLine {
    SystemNowPlayingLine(pid: pid, playing: playing, title: title, artist: artist, album: nil, artwork: artwork)
}

@Test func aHelperLineDecodes() throws {
    let json = #"{"pid":42,"playing":true,"title":"Video","artist":"Channel","album":"","artwork":"AQID"}"#
    let decoded = try JSONDecoder().decode(SystemNowPlayingLine.self, from: Data(json.utf8))
    #expect(decoded == SystemNowPlayingLine(pid: 42, playing: true, title: "Video", artist: "Channel", album: "", artwork: "AQID"))
}

@Test func aHelperLineBecomesAnEventWithArtwork() {
    var translator = SystemNowPlayingTranslator()
    let events = translator.events(for: line(artwork: "AQID"), appName: "Google Chrome")
    #expect(events.count == 1)
    #expect(events.first?.player == "Google Chrome")
    #expect(events.first?.state == .playing)
    #expect(events.first?.title == "Video")
    #expect(events.first?.artwork == Data([1, 2, 3]))

    let paused = translator.events(for: line(playing: false), appName: "Google Chrome")
    #expect(paused.map(\.state) == [.paused])
}

@Test func whenTheNowPlayingAppChangesThePreviousOneIsReportedStopped() {
    var translator = SystemNowPlayingTranslator()
    _ = translator.events(for: line(), appName: "Google Chrome")
    let events = translator.events(for: line(pid: 20, title: "Episode"), appName: "Podcasts")
    #expect(events.map(\.player) == ["Google Chrome", "Podcasts"])
    #expect(events.map(\.state) == [.stopped, .playing])
}

@Test func nothingPlayingAnywhereStopsTheLastApp() {
    var translator = SystemNowPlayingTranslator()
    _ = translator.events(for: line(), appName: "Safari")
    let events = translator.events(for: line(pid: 0, playing: false, title: "", artist: ""), appName: nil)
    #expect(events.map(\.player) == ["Safari"])
    #expect(events.map(\.state) == [.stopped])
    // And again: nothing more to report.
    let again = translator.events(for: line(pid: 0, playing: false, title: "", artist: ""), appName: nil)
    #expect(again.isEmpty)
}

@Test func aPlayerIsNamedAfterItsAppOrItsProgram() {
    let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    #expect(SystemNowPlayingWatcher.appName(path: helper) == "Google Chrome")
    #expect(SystemNowPlayingWatcher.appName(path: "/opt/homebrew/bin/mpv") == "mpv")
}

@Test func theLineSplitterJoinsPartsAndSplitsLines() {
    let splitter = LineSplitter()
    let first = splitter.append(Data("{\"a\":1}\n{\"b\"".utf8))
    let second = splitter.append(Data(":2}\n\n".utf8))
    #expect(first.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#])
    #expect(second.map { String(decoding: $0, as: UTF8.self) } == [#"{"b":2}"#])
}
