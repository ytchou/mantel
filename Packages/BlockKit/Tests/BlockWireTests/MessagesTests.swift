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

    @Test func nodeCountIsCapped() throws {
        let limit = ViewNode.vstack(Array(repeating: .spacer(), count: Contract.maxNodes - 1))
        #expect(limit.nodeCount == 200)
        try limit.validate()

        let over = ViewNode.vstack(Array(repeating: .spacer(), count: Contract.maxNodes))
        #expect(over.nodeCount == 201)
        #expect(throws: ViewNodeError.tooManyNodes(count: 201, limit: 200)) { try over.validate() }
    }

    /// Any change to the wire format fails here. If the change is meant,
    /// it is a new contract version.
    @Test func wireV1MatchesGoldenFile() throws {
        var lines: [String] = []
        for message in Samples.blockToHost {
            lines.append(String(decoding: try Framing.encode(message, generation: 1), as: UTF8.self))
        }
        for message in Samples.hostToBlock {
            lines.append(String(decoding: try Framing.encode(message, generation: 1), as: UTF8.self))
        }
        let actual = "[\n" + lines.joined(separator: ",\n") + "\n]\n"

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wire-v1.json")
        let expected = (try? String(contentsOf: fixture, encoding: .utf8)) ?? ""
        if actual != expected {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("wire-v1.actual.json")
            try actual.write(to: out, atomically: true, encoding: .utf8)
            Issue.record("wire format differs from Fixtures/wire-v1.json; actual written to \(out.path)")
        }
    }
}
