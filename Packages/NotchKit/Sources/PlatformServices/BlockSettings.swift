import Foundation
import NotchCore
import Observation
import os

/// Logger for this module. Each module or block uses its own category under
/// the same subsystem, so Console.app can filter on the subsystem.
enum Log {
    static let subsystem = "dev.topnotch.TopNotch"
    static let platform = Logger(subsystem: subsystem, category: "platform")
}

/// Bumped whenever a block is turned on or off through `BlockSettings`, or
/// its keys are cleared.
///
/// `NotchRuntime.isEnabled(_:)` is not observable, so views that show the
/// enabled state read this value to redraw when it changes. It works because
/// every on/off change in the app goes through `BlockSettings`: a block turned
/// off after failures goes through the closure the app gives `BlockStore`, and
/// Remove clears the block's keys with `clear(_:)`.
@MainActor
@Observable
final class EnablementSignal {
    static let shared = EnablementSignal()
    var revision = 0
}

/// Remembers which blocks are on. UserDefaults keys "block.<id>.enabled";
/// a block with no stored value is on.
@MainActor
public final class BlockSettings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(_ id: BlockID) -> String { "block.\(id.rawValue).enabled" }

    public func isEnabled(_ id: BlockID) -> Bool {
        _ = EnablementSignal.shared.revision
        // `bool(forKey:)`, not a cast: a launch argument such as
        // `-block.shelf.enabled NO` arrives as the string "NO".
        guard defaults.object(forKey: Self.key(id)) != nil else { return true }
        return defaults.bool(forKey: Self.key(id))
    }

    /// Stores the value and applies it to the runtime.
    public func setEnabled(_ id: BlockID, _ enabled: Bool, in runtime: NotchRuntime) {
        defaults.set(enabled, forKey: Self.key(id))
        runtime.setEnabled(id, enabled)
        EnablementSignal.shared.revision += 1
        Log.platform.info("Block \(id.rawValue, privacy: .public) turned \(enabled ? "on" : "off", privacy: .public)")
    }

    /// Deletes every key of a removed block: its settings, "<id>.*", and the
    /// app's keys for it, "block.<id>.*". Other blocks' keys are kept.
    public func clear(_ id: BlockID) {
        let prefixes = ["\(id.rawValue).", "block.\(id.rawValue)."]
        for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
        EnablementSignal.shared.revision += 1
        Log.platform.info("Block \(id.rawValue, privacy: .public) settings cleared")
    }
}
