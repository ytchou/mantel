import BlockWire
import Foundation
import Observation
import SwiftUI

/// Which view of a presentation a tree is for.
public enum RemoteSlot: Sendable, Hashable {
    case peek, wing, expanded
}

/// What a block process last sent for its view: one tree per slot and the
/// images those trees refer to. `NodeView` draws from it, so a new tree
/// redraws the view in place with no new presentation.
@MainActor
@Observable
public final class RemoteModel {
    public internal(set) var peek: ViewNode?
    public internal(set) var wing: ViewNode?
    public internal(set) var expanded: ViewNode?

    /// Images by asset id, decoded once.
    private var images: [String: NSImage] = [:]
    /// Asset ids, least recently sent or referenced first. The kit keeps the
    /// same order and evicts at the same moment (after the trees that refer
    /// to the images), so it knows which images to send again.
    @ObservationIgnored private var recency: [String] = []

    // MARK: Items (contract version 2)

    /// A click, double-click or menu entry on an `item`: its id and what was done.
    @ObservationIgnored var onItemAction: @MainActor (String, ItemAction) -> Void = { _, _ in }
    /// A drag-out of the `item` with this id is starting. Called in the same
    /// main-actor turn that starts the dragging session, before it starts.
    @ObservationIgnored var onDragBegan: @MainActor (String) -> Void = { _ in }
    /// That drag ended; true only when it ended with an operation.
    @ObservationIgnored var onDragEnded: @MainActor (String, Bool) -> Void = { _, _ in }

    /// The dragging source of every drag-out; see `ItemDragSource`.
    @ObservationIgnored let dragSource = ItemDragSource()
    /// Whether a file path may go on the drag pasteboard. The stand-in allows
    /// only paths its block's sandbox could read; other file entries are left out.
    @ObservationIgnored var mayDragFile: @MainActor (String) -> Bool = { _ in true }

    /// Reduce Motion, injected for tests; nil follows the system setting.
    @ObservationIgnored var reduceMotion: Bool?

    public init() {
        dragSource.onEnd = { [weak self] id, succeeded in self?.onDragEnded(id, succeeded) }
    }

    /// Whether `sweep` and a draining `progress` move: not with Reduce Motion.
    func animates(systemReduceMotion: Bool) -> Bool {
        !(reduceMotion ?? systemReduceMotion)
    }

    /// Starts a drag-out of the item `id`: tells the stand-in, then gives the
    /// source for the dragging session.
    func beginItemDrag(_ id: String) -> ItemDragSource {
        dragSource.begin(id)
        onDragBegan(id)
        return dragSource
    }

    public func tree(for slot: RemoteSlot) -> ViewNode? {
        switch slot {
        case .peek: peek
        case .wing: wing
        case .expanded: expanded
        }
    }

    /// Replaces the trees that are given; leaves the others as they are.
    /// Then marks the images they refer to as used and keeps the
    /// `Contract.assetCacheSize` most recent, as the kit does.
    func setTrees(peek: ViewNode?, wing: ViewNode?, expanded: ViewNode?) {
        if let peek { self.peek = peek }
        if let wing { self.wing = wing }
        if let expanded { self.expanded = expanded }
        touchAssets(in: [peek, wing, expanded].compactMap { $0 })
        trim(to: Contract.assetCacheSize)
    }

    func clear() {
        peek = nil
        wing = nil
        expanded = nil
        images = [:]
        recency = []
    }

    // MARK: Assets

    /// The most images held between two trees. The kit sends the images of
    /// one `present` or `update` just before it; a block that sends more
    /// without a tree loses the oldest.
    static let maxPendingAssets = Contract.assetCacheSize + 3 * Contract.maxNodes

    /// Keeps an image. Bytes that are not an image are kept as a missing
    /// image, so the view draws its placeholder. Nothing the kit counts as
    /// held is evicted here: that waits for the tree that refers to it.
    func storeAsset(id: String, bytes: Data) {
        images[id] = NSImage(data: bytes) ?? NSImage()
        markRecent(id)
        trim(to: Self.maxPendingAssets)
    }

    /// Marks every image the trees refer to as just used, in tree order.
    func touchAssets(in trees: [ViewNode]) {
        for id in trees.flatMap(\.assetIDs) where images[id] != nil {
            markRecent(id)
        }
    }

    func hasAsset(_ id: String) -> Bool { images[id] != nil }

    /// The image for an asset id, or nil when it never arrived or was evicted.
    func image(_ id: String) -> NSImage? {
        guard let image = images[id], image.isValid else { return nil }
        return image
    }

    private func markRecent(_ id: String) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    /// Evicts the least recently used images beyond `count`.
    private func trim(to count: Int) {
        while recency.count > count {
            images[recency.removeFirst()] = nil
        }
    }
}
