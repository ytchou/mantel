import CryptoKit
import Foundation

/// Images a block shows, sent to the app once and then referred to by id.
///
/// The id is the first 16 hex characters of the bytes' SHA-256, so the same
/// image always has the same id. The app keeps the `Contract.assetCacheSize`
/// images most recently sent or shown; this mirrors that list, so an image
/// the app has let go is sent again.
public struct Assets: Sendable {
    /// Bytes registered and not sent yet, oldest first.
    private var pending: [(id: String, bytes: Data)] = []
    /// Sent and still held by the app, least recently used first.
    private var sent: [(id: String, bytes: Data)] = []

    public init() {}

    public static func id(for bytes: Data) -> String {
        SHA256.hash(data: bytes).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Remembers the bytes and returns their id, for an `image` node.
    public mutating func register(_ bytes: Data) -> String {
        let id = Self.id(for: bytes)
        guard !sent.contains(where: { $0.id == id }), !pending.contains(where: { $0.id == id }) else { return id }
        pending.append((id, bytes))
        // Images built and never shown: keep only the newest few.
        if pending.count > Contract.assetCacheSize { pending.removeFirst() }
        return id
    }

    /// The images the trees refer to that the app does not hold, in tree
    /// order. Marks them sent and moves every referenced image to the most
    /// recent end. Ids with no known bytes are left out.
    public mutating func take(for trees: [ViewNode]) -> [(id: String, bytes: Data)] {
        var out: [(id: String, bytes: Data)] = []
        for id in trees.flatMap(\.assetIDs) {
            if let index = sent.firstIndex(where: { $0.id == id }) {
                sent.append(sent.remove(at: index))
            } else if let index = pending.firstIndex(where: { $0.id == id }) {
                let asset = pending.remove(at: index)
                out.append(asset)
                sent.append(asset)
            }
        }
        if sent.count > Contract.assetCacheSize { sent.removeFirst(sent.count - Contract.assetCacheSize) }
        return out
    }
}
