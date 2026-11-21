import BlockWire
import Foundation
import NotchCore

/// Stands in for a package in the Blocks folder that waits for the owner's
/// review: found there and never approved, or changed since its approval
/// (D9, D18). It is listed on the Blocks page, turned off with the reason,
/// so the owner can review and approve it, or remove it. It never runs
/// anything; `BlockStore.approve` replaces it with the block's stand-in.
@MainActor
final class PendingBlock: NotchBlock {
    let id: BlockID
    let title: String
    let info: BlockInfo
    let health: BlockHealth
    let review: BlockReview?
    /// The package folder in the Blocks folder, run once approved and deleted by Remove.
    let packageURL: URL

    init(manifest: Manifest, packageURL: URL, source: BlockSource, reason: BlockReview) {
        id = BlockID(rawValue: manifest.id)
        title = manifest.name
        self.packageURL = packageURL
        review = reason
        info = BlockInfo(summary: manifest.summary, symbol: manifest.symbol.isEmpty ? "square.grid.2x2" : manifest.symbol,
                         trigger: manifest.trigger, permissions: manifest.permissions + manifest.accessText,
                         version: manifest.version, source: source)
        health = .turnedOff(reason: Self.reason(reason))
    }

    /// The reason shown on the Blocks page, in the user's words.
    static func reason(_ review: BlockReview) -> String {
        switch review {
        case .new: "New: review this block before it runs."
        case .changed: "Changed: its package changed after you approved it. Review it again before it runs."
        }
    }

    func activate(_ context: any BlockContext) {}
}
