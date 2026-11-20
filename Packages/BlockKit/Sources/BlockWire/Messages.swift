import Foundation

/// What a message type is: `BlockToHost` or `HostToBlock`.
public typealias WireMessage = Codable & Hashable & Sendable

/// One frame on the wire: the process generation and one message.
///
/// The app starts each block process with a new generation and drops frames
/// that carry an old one.
public struct Envelope<Message: WireMessage>: Codable, Hashable, Sendable {
    public var generation: Int
    public var message: Message

    public init(generation: Int, message: Message) {
        self.generation = generation
        self.message = message
    }
}

// MARK: - Block to app

public enum BlockToHost: Codable, Hashable, Sendable {
    /// The first frame a block sends.
    case hello(contract: Int, id: String, version: String)
    /// The answer to `ping`, with the same `seq`.
    case pong(seq: Int)
    /// Ask for the notch. At least one slot is set. `seconds` is the only way
    /// to time a dismissal. With `dismissIfNotShown`, the app dismisses the
    /// presentation at once if it did not win the notch.
    case present(
        priority: Priority,
        peek: ViewSlot?,
        wing: ViewSlot?,
        expanded: ViewSlot?,
        opensAt: Level,
        seconds: Double?,
        dismissIfNotShown: Bool
    )
    /// Replace the trees of the current presentation. Sizes stay as presented.
    case update(peek: ViewNode?, wing: ViewNode?, expanded: ViewNode?)
    /// Give the notch back.
    case dismiss
    /// Image bytes (PNG or JPEG), referred to by `id` from `image` nodes.
    case asset(id: String, bytes: Data)
    /// The block's menu actions. Replaces the previous list.
    case actions(items: [ActionItem])
    /// A line for the app's log.
    case log(text: String)
}

/// How strongly a presentation asks for the notch.
public enum Priority: String, Codable, Hashable, Sendable, CaseIterable {
    case ambient, standard, interactive
}

/// The level a presentation opens at.
public enum Level: String, Codable, Hashable, Sendable, CaseIterable {
    case peek, expanded
}

/// One menu action offered by a block.
public struct ActionItem: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var enabled: Bool

    public init(id: String, title: String, enabled: Bool = true) {
        self.id = id
        self.title = title
        self.enabled = enabled
    }
}

// MARK: - App to block

public enum HostToBlock: Codable, Hashable, Sendable {
    /// The app's answer to `hello`. `settings` holds every declared setting's
    /// current value. `dataFolder` is a path the block may write to.
    case welcome(contract: Int, settings: [String: SettingValue], dataFolder: String)
    /// A heartbeat. Answer with `pong` and the same `seq`.
    case ping(seq: Int)
    /// A system event the block listens to. `replay` is true when the app
    /// resends the latest event to a block that just started: the block
    /// updates its state and does not present.
    case event(payload: EventPayload, replay: Bool)
    /// Whether the block's presentation is the one on screen.
    case owner(owns: Bool)
    /// The user clicked the block's view, or one of its buttons.
    case input(input: WireInput)
    /// The user chose one of the block's menu actions.
    case action(id: String)
    /// The user changed a setting.
    case setting(key: String, value: SettingValue)
    /// Stop. The block should exit.
    case quit
}

/// A click on the block's view.
public enum WireInput: Codable, Hashable, Sendable {
    case click
    case button(id: String)
}

/// A setting's value: a toggle is a bool, a choice is a string.
public enum SettingValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case string(String)

    public var bool: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }

    public var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    // Encoded as the bare JSON value: `true`, `"large"`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

// MARK: - Events

/// The system events a block can listen to, by wire name.
public enum WireEvent: String, Codable, Hashable, Sendable, CaseIterable {
    case pointerHover
    case outputVolume
    case nowPlaying
    case screenshotCaptured
    case dragStarted
    case dragEnded
}

/// The pointer entered or left the notch shape.
public struct PointerHover: Codable, Hashable, Sendable {
    public var isInside: Bool
    public init(isInside: Bool) { self.isInside = isInside }
}

/// The volume or mute state of the default output device changed.
public struct OutputVolume: Codable, Hashable, Sendable {
    /// 0 to 1.
    public var volume: Double
    public var isMuted: Bool
    public init(volume: Double, isMuted: Bool) {
        self.volume = volume
        self.isMuted = isMuted
    }
}

/// A music player started, paused or stopped, or changed track.
public struct NowPlaying: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case playing, paused, stopped
    }

    /// The player's app name, such as "Spotify".
    public var player: String
    public var state: State
    public var title: String
    public var artist: String
    public var album: String
    /// Image data (JPEG or PNG), up to 1 MB, when the source has it.
    public var artwork: Data?

    public init(player: String, state: State, title: String = "", artist: String = "", album: String = "", artwork: Data? = nil) {
        self.player = player
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
    }
}

/// A new screenshot file appeared.
public struct Screenshot: Codable, Hashable, Sendable {
    /// Absolute file path.
    public var path: String
    /// Seconds since 1970.
    public var createdAt: Double

    public init(path: String, createdAt: Double) {
        self.path = path
        self.createdAt = createdAt
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var date: Date { Date(timeIntervalSince1970: createdAt) }
}

/// A drag started somewhere on screen.
public struct DragStarted: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case file, link, text
    }

    /// What the drag carries, sorted by name.
    public var kinds: [Kind]
    public init(kinds: [Kind]) { self.kinds = kinds }
}

/// One event with its data. Encoded as `{"name": <WireEvent>, "value": {...}}`;
/// `dragEnded` has an empty value.
public enum EventPayload: Codable, Hashable, Sendable {
    case pointerHover(PointerHover)
    case outputVolume(OutputVolume)
    case nowPlaying(NowPlaying)
    case screenshotCaptured(Screenshot)
    case dragStarted(DragStarted)
    case dragEnded

    public var name: WireEvent {
        switch self {
        case .pointerHover: .pointerHover
        case .outputVolume: .outputVolume
        case .nowPlaying: .nowPlaying
        case .screenshotCaptured: .screenshotCaptured
        case .dragStarted: .dragStarted
        case .dragEnded: .dragEnded
        }
    }

    private enum CodingKeys: String, CodingKey { case name, value }
    private struct Empty: Codable {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(WireEvent.self, forKey: .name) {
        case .pointerHover: self = .pointerHover(try container.decode(PointerHover.self, forKey: .value))
        case .outputVolume: self = .outputVolume(try container.decode(OutputVolume.self, forKey: .value))
        case .nowPlaying: self = .nowPlaying(try container.decode(NowPlaying.self, forKey: .value))
        case .screenshotCaptured: self = .screenshotCaptured(try container.decode(Screenshot.self, forKey: .value))
        case .dragStarted: self = .dragStarted(try container.decode(DragStarted.self, forKey: .value))
        case .dragEnded: self = .dragEnded
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        switch self {
        case let .pointerHover(value): try container.encode(value, forKey: .value)
        case let .outputVolume(value): try container.encode(value, forKey: .value)
        case let .nowPlaying(value): try container.encode(value, forKey: .value)
        case let .screenshotCaptured(value): try container.encode(value, forKey: .value)
        case let .dragStarted(value): try container.encode(value, forKey: .value)
        case .dragEnded: try container.encode(Empty(), forKey: .value)
        }
    }
}
