import BlockWire
import SwiftUI
import Testing
@testable import BlockHost

@MainActor
struct NodeViewTests {
    /// One tree holding every node kind, with an image whose asset never arrived.
    static let everyNode: ViewNode = .hstack(spacing: 10, alignment: .center, padding: .init(horizontal: 18), [
        .box(width: 36, height: 36, cornerRadius: 8, fillOpacity: 0.12, .symbol("music.note", size: 15, opacity: 0.8)),
        .vstack(spacing: 2, alignment: .start, [
            .text("Title", style: .title),
            .text("Body", style: .body),
            .text("Secondary", style: .secondary),
        ]),
        .image(asset: "never-sent", size: 36, cornerRadius: 8).accessibilityLabel("Artwork"),
        .spacer(minLength: 4),
        .symbol("speaker.wave.2.fill", size: 12, opacity: 0.8, width: 18),
        .progress(1.4, width: 64).accessibilityLabel("Volume 100 percent"),
        .button(id: "skip", title: "Skip"),
    ])

    @Test func nodeViewBuildsEveryNode() throws {
        let model = RemoteModel()
        let kinds = Self.everyNode.children + Self.everyNode.children.flatMap(\.children) + [Self.everyNode]
        for node in kinds {
            let renderer = ImageRenderer(content: NodeView(node: node, model: model).frame(width: 380, height: 52))
            #expect(renderer.cgImage != nil, "\(node.kind)")
        }

        // A present asset draws as an image.
        let png = try #require(Self.onePixelPNG())
        model.storeAsset(id: "art", bytes: png)
        let image = ImageRenderer(content: NodeView(node: .image(asset: "art", size: 36, cornerRadius: 8), model: model))
        #expect(image.cgImage != nil)

        // The slot view draws what the model holds for its slot.
        model.peek = Self.everyNode
        #expect(ImageRenderer(content: RemoteSlotView(model: model, slot: .peek).frame(width: 380, height: 52)).cgImage != nil)
    }

    @Test func assetCacheKeepsTheMostRecentlyUsed() {
        let model = RemoteModel()
        for index in 0..<Contract.assetCacheSize {
            model.storeAsset(id: "a\(index)", bytes: Data([UInt8(index)]))
        }
        // Referencing the oldest makes it recent, so the next one evicts a1.
        model.touchAssets(in: [.image(asset: "a0", size: 10, cornerRadius: 0)])
        model.storeAsset(id: "new", bytes: Data([9]))
        #expect(model.hasAsset("a0"))
        #expect(!model.hasAsset("a1"))
        #expect(model.hasAsset("new"))
    }

    static func onePixelPNG() -> Data? {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
