import Foundation
import NotchCore
import Observation
import os

/// Logger for this module. Each module or block uses its own category under
/// the same subsystem, so Console.app can filter on the subsystem.
enum Log {
    static let subsystem = "dev.mantel.Mantel"
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

/// Remembers which blocks are on and their order. UserDefaults keys
/// "block.<id>.enabled" (a block with no stored value is on) and "block.order".
@MainActor
public final class BlockSettings {
    private let defaults: UserDefaults
    /// The persistent domain `defaults` writes to, searched by `clear`.
    private let domain: String?

    /// - Parameter domain: the persistent domain `defaults` writes to: the
    ///   app's bundle id for `.standard`, the suite name for a suite.
    public init(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.domain = domain
    }

    static func key(_ id: BlockID) -> String { "block.\(id.rawValue).enabled" }

    public func isEnabled(_ id: BlockID) -> Bool {
        _ = EnablementSignal.shared.revision
        // `bool(forKey:)`, not a cast: a launch argument such as
        // `-block.hello.enabled NO` arrives as the string "NO".
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

    // MARK: Order

    static let orderKey = "block.order"

    /// The blocks' rank, highest first, as stored in "block.order". Ids of
    /// blocks that are not registered may appear; registered blocks missing
    /// from it rank last. Empty with nothing stored: no id is ranked in code,
    /// so the blocks keep the order they were added in (installed blocks in
    /// install order, then the development block).
    public var order: [BlockID] {
        (defaults.stringArray(forKey: Self.orderKey) ?? []).map { BlockID(rawValue: $0) }
    }

    public func setOrder(_ ids: [BlockID]) {
        defaults.set(ids.map(\.rawValue), forKey: Self.orderKey)
    }

    /// Puts the runtime's blocks in the stored order. Blocks not in it keep
    /// their registration order after the others. Call once all blocks are
    /// registered at launch; it stores nothing. After an install, call
    /// `applyOrderAfterInstall(to:)` instead.
    public func applyOrder(to runtime: NotchRuntime) {
        runtime.setOrder(order)
    }

    /// After a block installed from the Blocks page is registered: puts the
    /// runtime's blocks in the stored order (the new block, not in it, goes
    /// last) and stores the result. At launch installed blocks are found
    /// sorted by id, so storing here is what keeps the install order.
    public func applyOrderAfterInstall(to runtime: NotchRuntime) {
        applyOrder(to: runtime)
        storeOrder(of: runtime)
    }

    /// Moves a block to `index` in the runtime and stores the new order.
    public func move(_ id: BlockID, to index: Int, in runtime: NotchRuntime) {
        runtime.move(id, to: index)
        storeOrder(of: runtime)
        Log.platform.info("Block \(id.rawValue, privacy: .public) moved to \(index, privacy: .public)")
    }

    /// Stores the runtime's order. Stored ids of blocks not registered now
    /// are kept, after the others.
    private func storeOrder(of runtime: NotchRuntime) {
        let ranked = runtime.blocks.map(\.id)
        setOrder(ranked + order.filter { !ranked.contains($0) })
    }

    // MARK: Remove

    /// Deletes every key of a removed block: its settings, "<id>.*", and the
    /// app's keys for it, "block.<id>.*", and takes it out of the stored
    /// order. Other blocks' keys are kept.
    public func clear(_ id: BlockID) {
        for key in storedKeys(of: id) {
            defaults.removeObject(forKey: key)
        }
        if let stored = defaults.stringArray(forKey: Self.orderKey), stored.contains(id.rawValue) {
            defaults.set(stored.filter { $0 != id.rawValue }, forKey: Self.orderKey)
        }
        EnablementSignal.shared.revision += 1
        Log.platform.info("Block \(id.rawValue, privacy: .public) settings cleared")
    }

    /// The block's keys the app stored, "<id>.*" and "block.<id>.*". Only the
    /// app's own domain is searched, not `dictionaryRepresentation()`, which
    /// also holds the global and registration domains.
    func storedKeys(of id: BlockID) -> [String] {
        guard let domain, let stored = defaults.persistentDomain(forName: domain) else { return [] }
        let prefixes = ["\(id.rawValue).", "block.\(id.rawValue)."]
        return stored.keys.filter { key in prefixes.contains(where: key.hasPrefix) }.sorted()
    }
}
