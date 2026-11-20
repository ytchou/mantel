import CryptoKit
import Foundation
import Testing
@testable import BlockKit
import BlockKitTesting

@MainActor
final class Artwork {
    var bytes = Data([1, 2, 3])
}

struct AssetsTests {
    @MainActor
    @Test func sameImageSentOnce() async throws {
        let art = Artwork()
        let host = FakeHost()
        host.run(TestBlock { ctx in
            ctx.on(.pointerHover) { _ in
                ctx.present(peek: ViewSlot(width: 380, height: 52, root: ctx.image(art.bytes, size: 36, cornerRadius: 8)))
            }
        })
        try await host.welcome()

        try host.send(hover)
        try host.send(hover)
        #expect(await host.messages(count: 2, isPresent).count == 2)
        let first = host.received.compactMap { if case let .asset(id, bytes) = $0 { (id, bytes) } else { nil } }
        #expect(first.count == 1)
        #expect(first.first?.0 == Assets.id(for: Data([1, 2, 3])))
        #expect(first.first?.1 == Data([1, 2, 3]))

        // The asset goes before the present that shows it.
        let kinds = host.received.map { message -> String in
            switch message {
            case .asset: "asset"
            case .present: "present"
            default: "other"
            }
        }
        #expect(kinds == ["other", "asset", "present", "present"])

        art.bytes = Data([4, 5, 6])
        try host.send(hover)
        #expect(await host.messages(count: 3, isPresent).count == 3)
        let assets = host.received.filter { if case .asset = $0 { true } else { false } }
        #expect(assets.count == 2)
        host.close()
    }

    @Test func idIsShortSHA256() {
        let bytes = Data("artwork".utf8)
        let full = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(Assets.id(for: bytes) == String(full.prefix(16)))
    }

    /// Takes for one tree, sending everything; returns the ids sent.
    private func sent(_ assets: inout Assets, _ ids: [String]) -> [String] {
        var out: [String] = []
        _ = assets.take(for: ids.map { .image(asset: $0, size: 1) }) { id, _ in
            out.append(id)
            return true
        }
        return out
    }

    @Test func imageTheAppLetGoIsSentAgain() {
        var assets = Assets()
        let firstID = assets.register(Data([0]))
        #expect(sent(&assets, [firstID]) == [firstID])

        // Eight other images push the first out of the app's cache.
        for n in 1...Contract.assetCacheSize {
            let id = assets.register(Data([UInt8(n)]))
            #expect(sent(&assets, [id]) == [id])
        }
        // Shown again from the node it already has, not registered again.
        #expect(sent(&assets, [firstID]) == [firstID])
    }

    @Test func aFailedSendIsNotCountedAsHeld() {
        var assets = Assets()
        let id = assets.register(Data([7]))
        let missing = assets.take(for: [.image(asset: id, size: 1)]) { _, _ in false }
        #expect(missing.isEmpty)
        #expect(sent(&assets, [id]) == [id], "tried again with the next tree")
        #expect(sent(&assets, [id]).isEmpty, "held now")
    }

    @Test func unknownIdIsReportedMissing() {
        var assets = Assets()
        #expect(assets.take(for: [.image(asset: "nobody", size: 1)]) { _, _ in true } == ["nobody"])
    }

    @Test func evictionOrderMatchesTheApp() {
        // The app's order: a tree's images are touched in tree order, then
        // the cache is trimmed. Referencing the oldest and a new image
        // evicts the second oldest, not the oldest.
        var assets = Assets()
        let ids = (0..<Contract.assetCacheSize).map { assets.register(Data([UInt8($0)])) }
        for id in ids { _ = sent(&assets, [id]) }
        let new = assets.register(Data([99]))
        #expect(sent(&assets, [ids[0], new]) == [new])
        #expect(sent(&assets, [ids[0]]).isEmpty, "the oldest is still held")
        #expect(sent(&assets, [ids[1]]) == [ids[1]], "the second oldest was let go")
    }

    @MainActor
    @Test func oversizedImageIsRefusedWithALogLine() async throws {
        let big = Data(count: 3_200_000)
        let host = FakeHost()
        host.run(TestBlock { ctx in
            ctx.on(.pointerHover) { _ in
                ctx.present(peek: ViewSlot(width: 380, height: 52, root: ctx.image(big, size: 36)))
            }
        })
        try await host.welcome()
        try host.send(hover)
        try host.send(hover)
        #expect(await host.messages(count: 2, isPresent).count == 2)

        #expect(!host.received.contains { if case .asset = $0 { true } else { false } })
        let logs = host.received.compactMap { if case let .log(text) = $0 { text } else { nil } }
        #expect(logs.count == 2, "one line per image node made: \(logs)")
        #expect(logs.allSatisfy { $0.contains("too large") })
        host.close()
    }
}
