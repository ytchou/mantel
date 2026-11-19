import Foundation

/// Something that happened in the system. Event sources publish events; blocks
/// subscribe to the types they care about.
///
/// An event is a plain value. Add a new event by declaring a new type; the bus
/// routes by type, so no central list has to change.
public protocol NotchEvent: Sendable {}

/// The kinds of content a drag can carry and a block can accept.
public enum DropKind: Sendable, Hashable, CaseIterable {
    case file
    case link
    case text
}

/// One dropped item, already resolved by the shell.
///
/// Promised files and raw image data are written to disk by the shell before
/// delivery, so a block never sees a promise. A folder is a `.file` whose URL
/// is a directory.
///
/// A file the shell wrote lives in a temporary folder that is emptied at the
/// next launch. A block that keeps such a file must move or copy it.
public enum DroppedItem: Sendable, Hashable {
    case file(URL)
    case link(URL)
    case text(String)

    public var kind: DropKind {
        switch self {
        case .file: .file
        case .link: .link
        case .text: .text
        }
    }
}

// MARK: - Events published by the shell

/// The pointer entered or left the notch shape.
///
/// Every subscribed block receives it, including blocks that do not own the
/// notch. This is how a block claims the notch on hover while it is idle.
public struct PointerHoverChanged: NotchEvent {
    public let isInside: Bool
    public init(isInside: Bool) { self.isInside = isInside }
}

// MARK: - Events published by event sources

/// A drag started somewhere on screen, in any app.
public struct DragSessionStarted: NotchEvent {
    /// What the drag carries, as far as the drag pasteboard shows.
    public let kinds: Set<DropKind>
    public init(kinds: Set<DropKind>) { self.kinds = kinds }
}

/// The drag ended (mouse-up), whether or not it was dropped on the notch.
/// A drop on the notch is delivered first, as `NotchInput.drop`.
public struct DragSessionEnded: NotchEvent {
    public init() {}
}

/// A new screenshot file appeared in the screenshot folder.
public struct ScreenshotCaptured: NotchEvent {
    public let url: URL
    public let createdAt: Date
    public init(url: URL, createdAt: Date) {
        self.url = url
        self.createdAt = createdAt
    }
}

/// The volume or mute state of the default output device changed, by the
/// volume keys, the menu bar or another app.
public struct OutputVolumeChanged: NotchEvent {
    /// 0 to 1.
    public let volume: Double
    public let isMuted: Bool
    public init(volume: Double, isMuted: Bool) {
        self.volume = volume
        self.isMuted = isMuted
    }
}

/// A music player started, paused or stopped, or changed track.
public struct NowPlayingChanged: NotchEvent {
    public enum State: Sendable, Equatable {
        case playing
        case paused
        /// Stopped, or the player quit.
        case stopped
    }

    /// The player's app name, such as "Spotify" or "Google Chrome". Sources
    /// that report the same app use the same name.
    public let player: String
    public let state: State
    public let title: String
    public let artist: String
    public let album: String
    /// Image data (JPEG or PNG), when the source has it.
    public let artwork: Data?

    public init(player: String, state: State, title: String = "", artist: String = "", album: String = "", artwork: Data? = nil) {
        self.player = player
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
    }
}
