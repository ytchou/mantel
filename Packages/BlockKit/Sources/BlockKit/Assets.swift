import CryptoKit
import Foundation

/// Images a block shows, sent to the app once and then referred to by id.
///
/// The id is the first 16 hex characters of the bytes' SHA-256, so the same
/// image always has the same id. The app keeps the `Contract.assetCacheSize`
/// images most recently sent or shown; this mirrors that list, so an image
/// the app has let go is sent again.
public struct Assets: Sendable {
    /// Bytes of the images registered or shown lately, least recently used
    /// first. Kept longer than the app keeps the images, so one the app let
    /// go can be sent again when it is shown again.
    private var known: [(id: String, bytes: Data)] = []
    /// The ids the app holds, least recently sent or shown first. The app
    /// keeps the same order and evicts at the same moment.
    private var held: [String] = []
    /// Ids of images too large to send, most recent last.
    private var refused: [String] = []

    /// How many images' bytes are kept.
    static let knownLimit = 2 * Contract.assetCacheSize
    /// Room in an `asset` frame for everything but the base64 bytes.
    static let frameOverhead = 256

    public init() {}

    public static func id(for bytes: Data) -> String {
        SHA256.hash(data: bytes).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether these bytes fit in one `asset` frame. They travel as base64,
    /// a third larger, so an image over about 3 MB does not.
    public static func fitsInFrame(_ bytes: Data) -> Bool {
        (bytes.count + 2) / 3 * 4 + frameOverhead <= Contract.maxFrameBytes
    }

    /// Remembers the bytes and returns their id, for an `image` node. Bytes
    /// that do not fit in a frame are never sent; the app draws a placeholder.
    public mutating func register(_ bytes: Data) -> String {
        let id = Self.id(for: bytes)
        guard Self.fitsInFrame(bytes) else {
            refused.removeAll { $0 == id }
            refused.append(id)
            if refused.count > Self.knownLimit { refused.removeFirst() }
            return id
        }
        if let index = known.firstIndex(where: { $0.id == id }) {
            known.append(known.remove(at: index))
        } else {
            known.append((id, bytes))
            if known.count > Self.knownLimit { known.removeFirst() }
        }
        return id
    }

    /// Sends, through `send`, each image the trees refer to that the app does
    /// not hold, in tree order, and moves every referenced image to the most
    /// recent end. An image counts as held only when `send` returns true.
    /// Returns the ids with no known bytes; refused ones are left out.
    public mutating func take(for trees: [ViewNode], send: (_ id: String, _ bytes: Data) -> Bool) -> [String] {
        var missing: [String] = []
        for id in trees.flatMap(\.assetIDs) {
            let knownIndex = known.firstIndex(where: { $0.id == id })
            if let knownIndex { known.append(known.remove(at: knownIndex)) }
            if let index = held.firstIndex(of: id) {
                held.append(held.remove(at: index))
            } else if knownIndex != nil, let bytes = known.last?.bytes {
                if send(id, bytes) { held.append(id) }
            } else if !refused.contains(id), !missing.contains(id) {
                missing.append(id)
            }
        }
        if held.count > Contract.assetCacheSize { held.removeFirst(held.count - Contract.assetCacheSize) }
        return missing
    }
}
