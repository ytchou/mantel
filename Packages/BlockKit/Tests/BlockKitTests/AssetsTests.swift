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

    @Test func imageTheAppLetGoIsSentAgain() {
        var assets = Assets()
        let first = Data([0])
        let firstID = assets.register(first)
        #expect(assets.take(for: [.image(asset: firstID, size: 1)]).map(\.id) == [firstID])

        // Eight other images push the first out of the app's cache.
        for n in 1...Contract.assetCacheSize {
            let id = assets.register(Data([UInt8(n)]))
            #expect(assets.take(for: [.image(asset: id, size: 1)]).count == 1)
        }
        _ = assets.register(first)
        #expect(assets.take(for: [.image(asset: firstID, size: 1)]).map(\.id) == [firstID])
    }
}
