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

    /// Every contract version 2 kind, and every version 1 kind with each new
    /// optional field set. Each must draw something: no kind falls back to
    /// an empty placeholder.
    static let amber = WireColor("#F5A623")
    static let everyV2Node: [ViewNode] = [
        .zstack(alignment: .bottomTrailing, [
            .box(width: 64, height: 64, cornerRadius: 8, fillOpacity: 0.12, .spacer()),
            .capsule(fill: WireColor("#FFFFFF"), padding: .init(horizontal: 5, vertical: 1),
                     .styledText("3", size: 10, weight: .bold, color: WireColor("#000000"), monospacedDigits: true)),
        ]),
        .scroll(.horizontal, .hstack(spacing: 10, [.text("Scrolled"), .text("Row")])),
        .styledText([.init("was "), .init("old-name", strikethrough: true)],
                    .init(size: 11, weight: .medium, color: amber, opacity: 0.55, lineLimit: 2, truncation: .middle)),
        .capsule(padding: .init(horizontal: 9), height: 22, .text("+2 next")),
        .sweep(amber),
        .frame(width: 76, height: 40, alignment: .topLeading, .text("Fixed")),
        .frame(fill: .both, .text("Filling")),
        .frame(fill: .width, alignment: .leading, .text("Wide")),
        .frame(fill: .height, .text("Tall")),
        .item(id: "tile", hoverFill: WireColor("#FFFFFF", opacity: 0.1), cornerRadius: 10,
              drag: .init([.file(path: "/tmp/a.png")], image: "thumb"),
              menu: [ActionItem(id: "remove", title: "Remove")], click: true, doubleClick: true, help: "a.png",
              .box(width: 64, height: 64, cornerRadius: 8, fillOpacity: 0.12, .symbol("doc", size: 22))),
        // Extended version 1 kinds.
        .box(cornerRadius: 14, fillOpacity: 0.06, color: amber,
             stroke: .init(color: WireColor("#FFFFFF", opacity: 0.7), width: 2, dash: [7, 5]),
             .text("Drop here", style: .title)),
        .symbol("sparkle", size: 11, color: amber, weight: .bold),
        .symbol("xmark.circle.fill", size: 16, color: WireColor("#000000"), secondaryColor: WireColor("#FFFFFF")),
        .button(id: "undo", title: "Undo", style: .accent, symbol: "arrow.uturn.backward", color: amber),
        .button(id: "keep", title: "Keep", style: .accent, color: amber, labelColor: WireColor("#000000", opacity: 0.85)),
        .button(id: "back", title: "Back", style: .plain, symbol: "chevron.left"),
        .button(id: "revert", title: "Revert", style: .capsule, enabled: false, color: amber, restOpacity: 0.6),
        .progress(0.8, color: amber),
        .progress(0.5, color: amber, track: WireColor("#FFFFFF", opacity: 0.15)),
        .progress(1, width: 120, color: amber, drainsOver: 5),
        .vstack(offset: .init(x: 4, y: 4), [.text("Moved")]),
        .hstack(offset: .init(x: -2, y: 0), [.text("Moved")]),
        // The fields added for the Shelf and Rename look.
        .hstack(spacing: 8, alignment: .firstTextBaseline, padding: .init(horizontal: 18, top: 6, bottom: 14), [
            .text("Shelf", style: .title),
            .styledText("2 items", size: 11, opacity: 0.5),
        ]),
        .vstack(alignment: .firstTextBaseline, [.text("Treated as start")]),
        .styledText("a-long-host.example.com", size: 9, weight: .medium, lineLimit: 2, alignment: .center),
        ViewNode.text("Tooltip").help("A tooltip"),
        ViewNode.spinner(.small).help("Waiting for dropped files"),
        ViewNode.button(id: "remove", title: "Remove from the shelf", style: .plain, restOpacity: 0.6,
                        label: .symbol("xmark.circle.fill", size: 16, color: WireColor("#000000"), secondaryColor: WireColor("#FFFFFF")))
            .help("Remove from the shelf"),
        .item(id: "tile-2", cornerRadius: 10, help: "a.png",
              overlay: .frame(fill: .both, alignment: .topTrailing, .hstack(offset: .init(x: 2, y: -2), [
                  .button(id: "remove:tile-2", title: "Remove", style: .plain, restOpacity: 0.6,
                          label: .symbol("xmark.circle.fill", size: 16, color: WireColor("#000000"), secondaryColor: WireColor("#FFFFFF"))),
              ])),
              .box(width: 64, height: 64, cornerRadius: 8, fillOpacity: 0.12, .symbol("doc", size: 22))),
    ]

    @Test func everyV2NodeBuildsAView() throws {
        let model = RemoteModel()
        for node in Self.everyV2Node {
            let renderer = ImageRenderer(content: NodeView(node: node, model: model)
                .foregroundStyle(.white)
                .frame(width: 200, height: 80))
            let image = try #require(renderer.cgImage, "\(node.kind)")
            switch node.kind {
            case .spinner, .scroll:
                // AppKit-backed: the renderer may not draw their pixels.
                break
            default:
                #expect(Self.hasInk(image), "\(node.kind) drew nothing")
            }
        }
        // AppKit-backed, so only built: an indeterminate spinner, both sizes.
        for size in [ViewNode.SpinnerSize.small, .mini] {
            #expect(ImageRenderer(content: NodeView(node: .spinner(size), model: model)).cgImage != nil)
        }
    }

    @Test func sweepAndDrainingProgressAreStillWithReduceMotion() {
        let model = RemoteModel()
        // Nothing injected: follows the system setting.
        #expect(model.animates(systemReduceMotion: false))
        #expect(!model.animates(systemReduceMotion: true))

        model.reduceMotion = true
        #expect(!model.animates(systemReduceMotion: false), "Reduce Motion injected as on stops the motion")

        model.reduceMotion = false
        #expect(model.animates(systemReduceMotion: true))

        // Still, they draw: the line in the middle, the bar at its value.
        model.reduceMotion = true
        for node: ViewNode in [.sweep(Self.amber), .progress(0.6, width: 100, color: Self.amber, drainsOver: 5)] {
            let renderer = ImageRenderer(content: NodeView(node: node, model: model).frame(width: 100, height: 36))
            #expect(renderer.cgImage.map(Self.hasInk) == true, "\(node.kind)")
        }
    }

    /// True when any pixel of the image is not fully transparent.
    nonisolated static func hasInk(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return false }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return stride(from: 3, to: width * height * 4, by: 4).contains { bytes[$0] > 0 }
    }

    @Test func assetCacheKeepsTheMostRecentlyUsed() {
        let model = RemoteModel()
        for index in 0..<Contract.assetCacheSize {
            model.storeAsset(id: "a\(index)", bytes: Data([UInt8(index)]))
            model.setTrees(peek: .image(asset: "a\(index)", size: 10, cornerRadius: 0), wing: nil, expanded: nil)
        }
        // As the kit does: a new tree refers to the oldest image and a new
        // one. The new image arrives first and evicts nothing; the tree then
        // makes both recent, and only then is the cache trimmed, so a1 goes.
        model.storeAsset(id: "new", bytes: Data([9]))
        #expect(model.hasAsset("a0"), "storing does not evict an image the next tree refers to")
        model.setTrees(peek: .hstack([
            .image(asset: "a0", size: 10, cornerRadius: 0),
            .image(asset: "new", size: 10, cornerRadius: 0),
        ]), wing: nil, expanded: nil)
        #expect(model.hasAsset("a0"))
        #expect(!model.hasAsset("a1"))
        #expect(model.hasAsset("new"))
        #expect((2..<Contract.assetCacheSize).allSatisfy { model.hasAsset("a\($0)") })
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
