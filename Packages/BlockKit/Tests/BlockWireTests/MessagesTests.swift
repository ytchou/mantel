import Foundation
import Testing
@testable import BlockWire

/// One of every message, used by the round-trip and golden-file tests.
enum Samples {
    static let leaf = ViewNode.text("Song", style: .title)

    static let slot = ViewSlot(width: 360, height: 44, root: .hstack(spacing: 10, [
        .box(width: 36, height: 36, cornerRadius: 8, fillOpacity: 0.12, .symbol("music.note", size: 15, opacity: 0.8)),
        .vstack(spacing: 2, alignment: .start, [.text("Song", style: .title), .text("Artist", style: .secondary)]),
        .spacer(minLength: 4),
        .symbol("speaker.wave.2.fill", size: 12, opacity: 0.8, width: 18),
        .progress(0.5, width: 64).accessibilityLabel("Volume 50 percent"),
    ]))

    static let blockToHost: [BlockToHost] = [
        .hello(contract: 1, id: "hello", version: "1.0.0"),
        .pong(seq: 7),
        .present(priority: .standard, peek: slot, wing: nil, expanded: nil, opensAt: .peek, seconds: 3, dismissIfNotShown: true),
        .present(priority: .interactive, peek: nil, wing: ViewSlot(width: 0, height: 0, root: leaf), expanded: slot, opensAt: .expanded, seconds: nil, dismissIfNotShown: false),
        .update(peek: leaf, wing: nil, expanded: nil),
        .dismiss,
        .asset(id: "0123456789abcdef", bytes: Data([0x89, 0x50, 0x4E, 0x47])),
        .actions(items: [ActionItem(id: "skip", title: "Skip"), ActionItem(id: "off", title: "Off", enabled: false)]),
        .log(text: "started"),
    ]

    static let events: [EventPayload] = [
        .pointerHover(PointerHover(isInside: true)),
        .outputVolume(OutputVolume(volume: 0.25, isMuted: false)),
        .nowPlaying(NowPlaying(player: "Spotify", state: .playing, title: "Song", artist: "Artist", album: "Album", artwork: Data([1, 2, 3]))),
        .nowPlaying(NowPlaying(player: "Music", state: .stopped)),
        .screenshotCaptured(Screenshot(path: "/Users/me/Desktop/Shot.png", createdAt: 1_700_000_000.5)),
        .dragStarted(DragStarted(kinds: [.file, .text])),
        .dragEnded,
    ]

    static let hostToBlock: [HostToBlock] = [
        .welcome(contract: 1, settings: ["showOnVolumeChange": .bool(true), "size": .string("large")], dataFolder: "/tmp/hello"),
        .ping(seq: 7),
    ] + events.map { .event(payload: $0, replay: false) } + [
        .event(payload: .pointerHover(PointerHover(isInside: false)), replay: true),
        .owner(owns: true),
        .input(input: .click),
        .input(input: .button(id: "play")),
        .action(id: "skip"),
        .setting(key: "showOnVolumeChange", value: .bool(false)),
        .quit,
    ]
}

struct MessagesTests {
    private func roundTrip<M: Codable & Hashable & Sendable>(_ message: M, generation: Int = 3) throws -> Envelope<M> {
        let body = try Framing.encode(message, generation: generation)
        return try Framing.decode(body, as: M.self)
    }

    @Test func everyMessageRoundTrips() throws {
        for message in Samples.blockToHost {
            #expect(try roundTrip(message) == Envelope(generation: 3, message: message))
        }
        for message in Samples.hostToBlock {
            #expect(try roundTrip(message) == Envelope(generation: 3, message: message))
        }
        // Every event name is covered.
        #expect(Set(Samples.events.map(\.name)) == Set(WireEvent.allCases))
    }

    @Test func everyNodeRoundTrips() throws {
        let nested = ViewNode.vstack(spacing: 4, alignment: .end, padding: .init(horizontal: 18, vertical: 2), [
            .hstack(alignment: .center, [
                .box(width: 36, height: 36, cornerRadius: 8, fillOpacity: 0.12, .image(asset: "abc", size: 36, cornerRadius: 8)),
                .vstack([.text("a"), .text("b", style: .secondary)]),
            ]),
            .symbol("star", size: 12),
            .progress(1, width: 64),
            .button(id: "go", title: "Go").accessibilityLabel("Start"),
            .spacer(),
        ]).accessibilityLabel("Panel")

        let kinds: [ViewNode] = [
            nested,
            .text("t", style: .body),
            .symbol("s", size: 10, opacity: 0.5, width: 18),
            .image(asset: "id", size: 20),
            .progress(0.3, width: 50),
            .button(id: "b", title: "B"),
            .spacer(minLength: 4),
        ]
        for node in kinds {
            #expect(try roundTrip(ViewSlot(width: 10, height: 20, root: node)).message.root == node)
        }
        #expect(nested.accessibilityLabel == "Panel")
        #expect(nested.assetIDs == ["abc"])
    }

    @Test func nodeLimitIs600AndAssetIDsIncludeItemDragImages() throws {
        #expect(Contract.maxNodes == 600)
        let limit = ViewNode.vstack(Array(repeating: .spacer(), count: 599))
        #expect(limit.nodeCount == 600)
        try limit.validate()

        let over = ViewNode.vstack(Array(repeating: .spacer(), count: 600))
        #expect(over.nodeCount == 601)
        #expect(throws: ViewNodeError.tooManyNodes(count: 601, limit: 600)) { try over.validate() }

        // Every new container counts its children.
        let containers: [ViewNode] = [
            .zstack([.spacer(), .spacer()]),
            .scroll(.horizontal, .hstack([.spacer()])),
            .capsule(.spacer()),
            .frame(width: 10, .spacer()),
            .item(id: "a", .spacer()),
        ]
        #expect(containers.map(\.nodeCount) == [3, 3, 2, 2, 2])

        // A drag image is an asset the app must hold, after the images
        // inside the item's view, without repeats.
        let tile = ViewNode.item(
            id: "tile",
            drag: ViewNode.ItemDrag([.file(path: "/tmp/a.png")], image: "drag"),
            .zstack([.image(asset: "thumb", size: 40), .image(asset: "drag", size: 10)])
        )
        #expect(ViewNode.vstack([tile, .image(asset: "other", size: 1)]).assetIDs == ["drag", "thumb", "other"])
        #expect(ViewNode.item(id: "x", drag: ViewNode.ItemDrag([.text(string: "t")], image: "only"), .spacer()).assetIDs == ["only"])
    }

    /// Any change to the wire format fails here. If the change is meant,
    /// it is a new contract version.
    @Test func wireV1MatchesGoldenFile() throws {
        try matchGoldenFile("wire-v1.json", blockToHost: Samples.blockToHost, hostToBlock: Samples.hostToBlock)
    }

    /// Decoding the version 1 file and encoding it again gives the same bytes:
    /// version 2 adds nothing to a version 1 message.
    @Test func goldenV1StillDecodesAndEncodesUnchanged() throws {
        try decodeAndEncodeGoldenFile("wire-v1.json", blockToHostCount: Samples.blockToHost.count)
    }

    @Test func goldenV2RoundTrips() throws {
        try matchGoldenFile("golden-v2.json", blockToHost: SamplesV2.blockToHost, hostToBlock: SamplesV2.hostToBlock)
        try decodeAndEncodeGoldenFile("golden-v2.json", blockToHostCount: SamplesV2.blockToHost.count)
        for message in SamplesV2.blockToHost {
            #expect(try roundTrip(message) == Envelope(generation: 3, message: message))
        }
        for message in SamplesV2.hostToBlock {
            #expect(try roundTrip(message) == Envelope(generation: 3, message: message))
        }
        // Every new node kind is in the file.
        let kinds = Set(SamplesV2.everyNode.flatMap(\.allNodes).map(\.kind.name))
        for name in ["zstack", "scroll", "styledText", "capsule", "spinner", "sweep", "frame", "item"] {
            #expect(kinds.contains(name), "golden-v2.json has no \(name)")
        }
    }

    @Test func v1NodeEncodesWithoutV2Fields() throws {
        // The keys inside `{"kind": {"<name>": {...}}}` for each version 1 builder.
        let expected: [(ViewNode, Set<String>)] = [
            (.vstack(spacing: 1, alignment: .start, padding: .init(horizontal: 1), [.spacer()]), ["children", "spacing", "alignment", "padding"]),
            (.hstack([.spacer()]), ["children"]),
            (.box(width: 1, height: 1, cornerRadius: 1, fillOpacity: 1, .spacer()), ["child", "width", "height", "cornerRadius", "fillOpacity"]),
            (.text("t"), ["text", "style"]),
            (.symbol("s", size: 1, opacity: 1, width: 1), ["name", "size", "opacity", "width"]),
            (.image(asset: "a", size: 1), ["asset", "size", "cornerRadius"]),
            (.progress(0.5, width: 10), ["value", "width"]),
            (.button(id: "b", title: "B"), ["id", "title"]),
            (.spacer(minLength: 1), ["minLength"]),
        ]
        for (node, keys) in expected {
            let data = try Framing.encoder().encode(node)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let kind = try #require(object["kind"] as? [String: Any])
            let fields = try #require(kind.values.first as? [String: Any])
            #expect(Set(fields.keys) == keys, "\(node.kind.name)")
        }
    }

    @Test func itemNodeCarriesDragMenuAndActions() throws {
        let item = ViewNode.item(
            id: "tile-1",
            hoverFill: WireColor("#FFFFFF", opacity: 0.08),
            cornerRadius: 10,
            drag: ViewNode.ItemDrag([.file(path: "/tmp/a.png"), .link(url: "https://example.com"), .text(string: "hello")], image: "thumb"),
            menu: [ActionItem(id: "open", title: "Open"), ActionItem(id: "remove", title: "Remove", enabled: false)],
            click: true,
            doubleClick: true,
            help: "a.png",
            .image(asset: "thumb", size: 40, cornerRadius: 6)
        )
        let decoded = try roundTrip(ViewSlot(width: 60, height: 60, root: item)).message.root
        #expect(decoded == item)
        guard case let .item(id, _, _, _, drag, menu, click, doubleClick, help) = decoded.kind else {
            Issue.record("not an item")
            return
        }
        #expect(id == "tile-1")
        #expect(drag?.items == [.file(path: "/tmp/a.png"), .link(url: "https://example.com"), .text(string: "hello")])
        #expect(drag?.image == "thumb")
        #expect(menu?.map(\.id) == ["open", "remove"])
        #expect(click == true && doubleClick == true && help == "a.png")

        // The answers the app sends for it.
        for input: WireInput in [.item(id: "tile-1", action: .click), .item(id: "tile-1", action: .doubleClick), .item(id: "tile-1", action: .menu(id: "open"))] {
            #expect(try roundTrip(HostToBlock.input(input: input)).message == .input(input: input))
        }
    }
}

// MARK: - Golden files

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
}

/// Encodes the samples, one envelope per line, and compares with the file.
private func matchGoldenFile(_ name: String, blockToHost: [BlockToHost], hostToBlock: [HostToBlock]) throws {
    var lines: [String] = []
    for message in blockToHost {
        lines.append(String(decoding: try Framing.encode(message, generation: 1), as: UTF8.self))
    }
    for message in hostToBlock {
        lines.append(String(decoding: try Framing.encode(message, generation: 1), as: UTF8.self))
    }
    let actual = "[\n" + lines.joined(separator: ",\n") + "\n]\n"

    let expected = (try? String(contentsOf: fixtureURL(name), encoding: .utf8)) ?? ""
    if actual != expected {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(name.replacingOccurrences(of: ".json", with: ".actual.json"))
        try actual.write(to: out, atomically: true, encoding: .utf8)
        Issue.record("wire format differs from Fixtures/\(name); actual written to \(out.path)")
    }
}

/// Decodes each line of the file and encodes it again: the bytes must match.
/// The first `blockToHostCount` lines are block-to-app messages.
private func decodeAndEncodeGoldenFile(_ name: String, blockToHostCount: Int) throws {
    let text = try String(contentsOf: fixtureURL(name), encoding: .utf8)
    let raw: [String] = text.split(separator: "\n").map(String.init)
    let kept: [String] = raw.filter { (line: String) -> Bool in line != "[" && line != "]" }
    let lines: [String] = kept.map { (line: String) -> String in
        line.hasSuffix(",") ? String(line.dropLast()) : line
    }
    #expect(lines.count > blockToHostCount)
    for (index, line) in lines.enumerated() {
        let body = Data(line.utf8)
        let again: Data
        if index < blockToHostCount {
            let envelope = try Framing.decode(body, as: BlockToHost.self)
            again = try Framing.encode(envelope.message, generation: envelope.generation)
        } else {
            let envelope = try Framing.decode(body, as: HostToBlock.self)
            again = try Framing.encode(envelope.message, generation: envelope.generation)
        }
        #expect(String(decoding: again, as: UTF8.self) == line, "\(name) line \(index + 2)")
    }
}

private extension ViewNode {
    /// This node and every node below it.
    var allNodes: [ViewNode] { [self] + children.flatMap(\.allNodes) }
}

private extension ViewNode.Kind {
    /// The wire name of the kind: the single key it encodes under.
    var name: String {
        let data = (try? Framing.encoder().encode(self)) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return object?.keys.first ?? ""
    }
}

/// One of every version 2 addition, used by the golden-v2 test.
enum SamplesV2 {
    static let amber = WireColor("#F5A623")
    static let dim = WireColor("#FFFFFF", opacity: 0.5)

    static let tile = ViewNode.item(
        id: "tile-1",
        hoverFill: WireColor("#FFFFFF", opacity: 0.08),
        cornerRadius: 10,
        drag: ViewNode.ItemDrag([.file(path: "/tmp/a.png"), .link(url: "https://example.com/a"), .text(string: "hello")], image: "0123456789abcdef"),
        menu: [ActionItem(id: "open", title: "Open"), ActionItem(id: "remove", title: "Remove", enabled: false)],
        click: true,
        doubleClick: true,
        help: "a.png",
        .frame(width: 56, height: 56, alignment: .topTrailing, .zstack(alignment: .topTrailing, [
            .image(asset: "0123456789abcdef", size: 48, cornerRadius: 6),
            .capsule(fill: amber, padding: .init(horizontal: 5, vertical: 1), height: 16,
                     .styledText("3", size: 10, weight: .bold, monospacedDigits: true)),
        ]))
    )

    /// Every new kind and every extended field.
    static let root = ViewNode.vstack(spacing: 6, offset: .init(x: 0, y: -2), [
        .hstack(alignment: .center, offset: .init(x: 4, y: 0), [
            .scroll(.horizontal, .hstack(spacing: 8, [tile])),
            .spinner(.small),
            .spinner(.mini),
        ]),
        .scroll(.vertical, .vstack([
            .styledText(
                [ViewNode.TextRun("old-name.png", strikethrough: true), ViewNode.TextRun(" new-name.png")],
                ViewNode.TextAttributes(size: 12, weight: .medium, color: dim, opacity: 0.9, lineLimit: 1, truncation: .middle, monospacedDigits: false)
            ),
        ])),
        .zstack([
            .box(width: 120, height: 60, cornerRadius: 12, fillOpacity: 0.1, color: amber,
                 stroke: ViewNode.Stroke(color: dim, width: 1.5, dash: [4, 3]), .spacer()),
            .sweep(amber),
        ]),
        .box(cornerRadius: 8, fillOpacity: 0, stroke: ViewNode.Stroke(color: amber, width: 1), .text("Drop here")),
        .frame(fill: .width, .spacer()),
        .symbol("checkmark.circle.fill", size: 14, color: amber, weight: .semibold, secondaryColor: dim),
        .button(id: "undo", title: "Undo", style: .accent, symbol: "arrow.uturn.backward", enabled: true, color: amber, restOpacity: 0.7,
                labelColor: WireColor("#000000", opacity: 0.85)),
        .button(id: "revert", title: "Revert", style: .plain, enabled: false),
        .button(id: "keep", title: "Keep", style: .capsule),
        .progress(1, color: amber, drainsOver: 5, track: WireColor("#FFFFFF", opacity: 0.15)),
        .progress(0.25, width: 80),
    ])

    static let everyNode: [ViewNode] = [root]

    static let blockToHost: [BlockToHost] = [
        .hello(contract: 2, id: "shelf", version: "2.0.0"),
        .present(priority: .interactive, peek: nil, wing: nil,
                 expanded: ViewSlot(width: 420, height: 140, root: root), opensAt: .expanded,
                 seconds: nil, dismissIfNotShown: false, accepts: [.file, .link, .text], answering: nil),
        .present(priority: .standard, peek: ViewSlot(width: 300, height: 40, root: .text("Named")), wing: nil, expanded: nil,
                 opensAt: .peek, seconds: 4, dismissIfNotShown: true, accepts: nil, answering: 12),
        .preview(paths: ["/tmp/a.png", "/tmp/b.pdf"]),
        .settingNote(key: "model", text: "Model ready"),
    ]

    static let hostToBlock: [HostToBlock] = [
        .welcome(contract: 2, settings: [:], dataFolder: "/tmp/shelf"),
        .event(payload: .dragStarted(DragStarted(kinds: [.file])), replay: false, seq: 12),
        .event(payload: .dragEnded, replay: true, seq: 13),
        .input(input: .drop(items: [.file(path: "/tmp/a.png"), .link(url: "https://example.com/a"), .text(string: "hello")])),
        .input(input: .item(id: "tile-1", action: .click)),
        .input(input: .item(id: "tile-1", action: .doubleClick)),
        .input(input: .item(id: "tile-1", action: .menu(id: "open"))),
        .input(input: .dragBegan(id: "tile-1")),
        .input(input: .dragEnded(id: "tile-1", succeeded: true)),
    ]
}
