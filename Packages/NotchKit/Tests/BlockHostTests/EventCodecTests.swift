import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

struct EventCodecTests {
    @Test func everyExposedEventEncodes() throws {
        let artwork = Data([1, 2, 3])
        let shot = Date(timeIntervalSince1970: 1_700_000_000.5)
        let cases: [(any NotchEvent, EventPayload)] = [
            (PointerHoverChanged(isInside: true), .pointerHover(PointerHover(isInside: true))),
            (OutputVolumeChanged(volume: 0.25, isMuted: true), .outputVolume(OutputVolume(volume: 0.25, isMuted: true))),
            (NowPlayingChanged(player: "Música", state: .paused, title: "Señorita", artist: "Ana", album: "Á", artwork: artwork),
             .nowPlaying(NowPlaying(player: "Música", state: .paused, title: "Señorita", artist: "Ana", album: "Á", artwork: artwork))),
            (ScreenshotCaptured(url: URL(fileURLWithPath: "/Users/me/Desktop/Screen Shot.png"), createdAt: shot),
             .screenshotCaptured(Screenshot(path: "/Users/me/Desktop/Screen Shot.png", createdAt: 1_700_000_000.5))),
            (DragSessionStarted(kinds: [.text, .file, .link]), .dragStarted(DragStarted(kinds: [.file, .link, .text]))),
            (DragSessionEnded(), .dragEnded),
        ]

        #expect(Set(cases.map(\.1.name)) == Set(WireEvent.allCases))
        for (event, payload) in cases {
            #expect(EventCodec.payload(for: event) == payload)
            #expect(try EventCodec.wireEvent(named: payload.name.rawValue) == payload.name)
        }

        // Artwork over the inbound limit is left out rather than sent.
        let huge = Data(count: EventCodec.maxArtworkBytes + 1)
        let big = EventCodec.payload(for: NowPlayingChanged(player: "Spotify", state: .playing, artwork: huge))
        #expect(big == .nowPlaying(NowPlaying(player: "Spotify", state: .playing, artwork: nil)))
    }

    // MARK: Catalog

    @Test func everyWireEventHasACatalogEntry() {
        for event in WireEvent.allCases {
            let entry = EventCatalog.entry(for: event)
            #expect(!entry.name.isEmpty, "\(event) has no name")
            #expect(!entry.reveals.isEmpty, "\(event) does not say what it reveals")
        }
    }

    @Test func theScreenshotEventNamesItsPermission() {
        #expect(EventCatalog.entry(for: .screenshotCaptured).permission == .screenshotFolder)
        for event in WireEvent.allCases where event != .screenshotCaptured {
            #expect(EventCatalog.entry(for: event).permission == EventEntry.Permission.none, "\(event)")
        }
    }

    @Test func theNowPlayingEntryDisclosesTheUndocumentedSource() {
        let note = EventCatalog.entry(for: .nowPlaying).note
        #expect(!note.isEmpty)
        #expect(note.contains("undocumented"))
    }

    @Test func unknownEventNamesAreRejected() {
        #expect(throws: EventCodecError.unknownEvent("keyPressed")) {
            try EventCodec.wireEvent(named: "keyPressed")
        }
        struct Unexposed: NotchEvent {}
        #expect(EventCodec.payload(for: Unexposed()) == nil)
    }
}
