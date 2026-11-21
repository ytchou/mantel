import BlockWire
import NotchCore

/// One entry per event a block can listen to: what it reveals and which macOS
/// permission it needs. A new `WireEvent` case does not compile without one.
enum EventCatalog {
    static func entry(for event: WireEvent) -> EventEntry {
        switch event {
        case .pointerHover:
            EventEntry(name: "Pointer over the notch",
                       reveals: "The pointer entered or left the notch")
        case .dragStarted:
            EventEntry(name: "Dragging starts",
                       reveals: "A drag is under way, and the kinds of things in it (file, link, text), never their content")
        case .dragEnded:
            EventEntry(name: "Dragging ends",
                       reveals: "A drag has ended, and the kinds of things in it (file, link, text), never their content")
        case .screenshotCaptured:
            EventEntry(name: "Screenshots",
                       reveals: "The path and time of a new screenshot",
                       permission: .screenshotFolder)
        case .outputVolume:
            EventEntry(name: "Volume changes",
                       reveals: "The output volume and mute state")
        case .nowPlaying:
            EventEntry(name: "Music playing",
                       reveals: "Player, state, title, artist, artwork",
                       note: "Other players are read from an undocumented part of macOS and may stop working after an update")
        }
    }
}
