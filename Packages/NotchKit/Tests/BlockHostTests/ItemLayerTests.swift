import AppKit
import BlockWire
import Testing
@testable import BlockHost

@MainActor
struct ItemLayerTests {
    @Test func itemPayloadsBuildPasteboardWriters() throws {
        let file = try #require(ItemDragSource.writer(for: .file(path: "/tmp/shot.png")) as? NSURL)
        #expect(file.isFileURL)
        #expect(file.path == "/tmp/shot.png")

        let link = try #require(ItemDragSource.writer(for: .link(url: "https://example.com/a")) as? NSURL)
        #expect(!link.isFileURL)
        #expect(link.absoluteString == "https://example.com/a")

        let text = try #require(ItemDragSource.writer(for: .text(string: "hello")) as? NSString)
        #expect(text as String == "hello")

        // The model builds one payload per entry, each with a drag image.
        let model = RemoteModel()
        let payloads = model.dragPayloads(for: .init([.file(path: "/tmp/shot.png"), .link(url: "https://example.com"), .text(string: "hi")]))
        #expect(payloads.count == 3)
        #expect(payloads[0].writer is NSURL)
        #expect(payloads[1].writer is NSURL)
        #expect(payloads[2].writer is NSString)
    }

    @Test func itemActionsCallTheHandler() throws {
        let model = RemoteModel()
        var calls: [(String, ItemAction)] = []
        model.onItemAction = { id, action in calls.append((id, action)) }

        let view = ItemLayerNSView()
        view.config = ItemLayer(
            id: "tile", model: model, drag: nil,
            menu: [ActionItem(id: "look", title: "Quick Look"), ActionItem(id: "remove", title: "Remove")],
            click: true, doubleClick: true, onHover: { _ in }
        )
        view.handleClick(count: 1)
        view.handleClick(count: 2)
        let menu = try #require(view.makeMenu())
        #expect(menu.items.map(\.title) == ["Quick Look", "Remove"])
        menu.performActionForItem(at: 1)

        #expect(calls.map(\.0) == ["tile", "tile", "tile"])
        #expect(calls.map(\.1) == [.click, .doubleClick, .menu(id: "remove")])

        // Click and double-click are sent only when set to true; no menu, no menu.
        calls = []
        view.config = ItemLayer(id: "quiet", model: model, drag: nil, menu: [], click: false, doubleClick: false, onHover: { _ in })
        view.handleClick(count: 1)
        view.handleClick(count: 2)
        #expect(view.makeMenu() == nil)
        #expect(calls.isEmpty)
    }

    @Test func dragSourceAllowsCopyOutsideTheAppOnly() {
        #expect(ItemDragSource.operationMask(for: .outsideApplication) == [.copy, .generic])
        #expect(ItemDragSource.operationMask(for: .withinApplication) == [])
    }

    @Test func dragEndReportsSuccessOnlyForANonEmptyOperation() {
        let model = RemoteModel()
        var began: [String] = []
        var ended: [(String, Bool)] = []
        model.onDragBegan = { began.append($0) }
        model.onDragEnded = { id, succeeded in ended.append((id, succeeded)) }

        // The model owns the source, so it outlives any view.
        let source = model.beginItemDrag("a")
        #expect(source === model.dragSource)
        source.end(operation: [])
        _ = model.beginItemDrag("b")
        source.end(operation: .copy)
        // No drag in progress: nothing to report.
        source.end(operation: .copy)

        #expect(began == ["a", "b"])
        #expect(ended.map(\.0) == ["a", "b"])
        #expect(ended.map(\.1) == [false, true])
    }
}
