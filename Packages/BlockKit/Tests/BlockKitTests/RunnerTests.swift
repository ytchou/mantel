import Foundation
import Testing
@testable import BlockKit
import BlockKitTesting

/// A block whose `start` is supplied by the test.
struct TestBlock: Block {
    let id: String
    let version: String
    let contract: Int
    let onStart: @MainActor (Context) -> Void

    init() { self.init { _ in } }

    init(id: String = "test", version: String = "1.0", contract: Int = Contract.current, _ onStart: @escaping @MainActor (Context) -> Void) {
        self.id = id
        self.version = version
        self.contract = contract
        self.onStart = onStart
    }

    func start(_ ctx: Context) { onStart(ctx) }
}

/// Things a block saw, for the test to read.
@MainActor
final class Seen {
    var events: [BlockEvent] = []
    var settingAtStart: Bool?
    var dataFolder: URL?
    var changes: [(String, SettingValue)] = []
    var drops: [[WireDrop]] = []
    var items: [(String, ItemAction)] = []
    var drags: [String] = []
    var inputs: [WireInput] = []
    var session: URLSession?
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

let hover = HostToBlock.event(payload: .pointerHover(PointerHover(isInside: true)), replay: false)

func isPresent(_ message: BlockToHost) -> Bool { if case .present = message { true } else { false } }

struct RunnerTests {
    @MainActor
    @Test func helloIsFirstFrame() async throws {
        let host = FakeHost()
        host.run(TestBlock(id: "hello", version: "2.1") { ctx in ctx.log("started") })

        let hello = await host.waitFor { if case .hello = $0 { true } else { false } }
        #expect(hello == .hello(contract: Contract.current, id: "hello", version: "2.1"))
        try await host.welcome()
        _ = await host.waitFor { $0 == .log(text: "started") }

        let envelopes = host.receivedEnvelopes
        #expect(envelopes.first == Envelope(generation: host.generation, message: .hello(contract: Contract.current, id: "hello", version: "2.1")))
        #expect(envelopes.count == 2)
        host.close()
    }

    @MainActor
    @Test func eventReachesHandler() async throws {
        let seen = Seen()
        let host = FakeHost()
        host.run(TestBlock { ctx in ctx.on(.pointerHover) { seen.events.append($0) } })
        try await host.welcome()

        try host.send(hover)
        try host.send(.event(payload: .pointerHover(PointerHover(isInside: false)), replay: true))
        // An event with no handler is ignored.
        try host.send(.event(payload: .dragEnded, replay: false))

        #expect(await eventually { seen.events.count == 2 })
        #expect(seen.events.map(\.pointerHover?.isInside) == [true, false])
        #expect(seen.events.map(\.replay) == [false, true])
        host.close()
    }

    @MainActor
    @Test func presentSendsTree() async throws {
        let slot = ViewSlot(width: 380, height: 52, root: .hstack([.text("Hi", style: .title), .spacer()]))
        let host = FakeHost()
        host.run(TestBlock { ctx in
            ctx.on(.pointerHover) { _ in ctx.present(peek: slot, for: 3) }
        })
        try await host.welcome()
        try host.send(hover)

        let presents = await host.messages(count: 1, isPresent)
        #expect(presents == [
            .present(priority: .standard, peek: slot, wing: nil, expanded: nil, opensAt: .peek, seconds: 3, dismissIfNotShown: false),
        ])
        // Nothing else was sent for it: no asset, no second present.
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.received.count == 2)
        host.close()
    }

    @Test func pongAnsweredOnMain() async throws {
        let host = FakeHost()
        host.run(await TestBlock())
        try await host.welcome()

        try host.send(.ping(seq: 5))
        #expect(await host.waitFor { $0 == .pong(seq: 5) } != nil)

        // Block the main queue: the ping is read but not answered.
        let gate = DispatchSemaphore(value: 0)
        let blocked = Flag()
        DispatchQueue.main.async {
            blocked.set()
            gate.wait()
        }
        while !blocked.isSet { try await Task.sleep(for: .milliseconds(5)) }
        try host.send(.ping(seq: 6))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!host.received.contains(.pong(seq: 6)))

        gate.signal()
        #expect(await host.waitFor { $0 == .pong(seq: 6) } != nil)
        host.close()
    }

    @Test func quitStopsRunner() async throws {
        // By quit.
        let host = FakeHost()
        let run = host.run(await TestBlock())
        try await host.welcome()
        try host.send(.quit)
        #expect(await finishes(run))

        // By the app closing the connection.
        let other = FakeHost()
        let otherRun = other.run(await TestBlock())
        try await other.welcome()
        other.close()
        #expect(await finishes(otherRun))
    }

    @MainActor
    @Test func settingsAvailableAtStart() async throws {
        let seen = Seen()
        let host = FakeHost()
        host.run(TestBlock { ctx in
            seen.settingAtStart = ctx.bool("loud")
            seen.dataFolder = ctx.dataFolder
            ctx.onSettingChanged { key, value in
                seen.changes.append((key, value))
                // The new value is readable inside the handler.
                seen.settingAtStart = ctx.bool("loud")
            }
        })
        try await host.welcome(settings: ["loud": .bool(true)], dataFolder: "/tmp/block-data")

        #expect(await eventually { seen.dataFolder != nil })
        #expect(seen.settingAtStart == true)
        #expect(seen.dataFolder?.path == "/tmp/block-data")

        try host.send(.setting(key: "loud", value: .bool(false)))
        #expect(await eventually { seen.changes.count == 1 })
        #expect(seen.changes.first?.0 == "loud" && seen.changes.first?.1 == .bool(false))
        #expect(seen.settingAtStart == false)
        host.close()
    }

    /// The kit's session goes through the gate at the port from `welcome`;
    /// without a port it has no proxy.
    @MainActor
    @Test func theKitSessionUsesTheGatePort() async throws {
        var proxies: [[AnyHashable: Any]?] = []
        for port in [4321, nil] as [Int?] {
            let seen = Seen()
            let host = FakeHost()
            host.run(TestBlock { ctx in seen.session = ctx.urlSession })
            try await host.welcome(gatePort: port)
            #expect(await eventually { seen.session != nil })
            proxies.append(seen.session?.configuration.connectionProxyDictionary)
            host.close()
        }

        let gate = try #require(proxies.first ?? nil)
        #expect(gate[kCFNetworkProxiesHTTPSEnable as String] as? Int == 1)
        #expect(gate[kCFNetworkProxiesHTTPSProxy as String] as? String == "127.0.0.1")
        #expect(gate[kCFNetworkProxiesHTTPSPort as String] as? Int == 4321)
        // Only the HTTPS proxy: plain HTTP is not routed through the gate.
        #expect(gate[kCFNetworkProxiesHTTPEnable as String] == nil)
        let none = proxies.last ?? nil
        #expect(none == nil || none?.isEmpty == true)
    }

    // MARK: Contract version 2

    @MainActor
    @Test func presentInsideEventHandlerSetsAnswering() async throws {
        let slot = ViewSlot(width: 300, height: 40, root: .text("Hi"))
        let host = FakeHost()
        host.run(TestBlock { ctx in
            ctx.on(.pointerHover) { _ in ctx.present(peek: slot, dismissIfNotShown: true) }
            // Outside a handler: a click is input, not an event.
            ctx.onInput { _ in ctx.present(peek: slot, accepts: [.file]) }
        })
        try await host.welcome()

        try host.event(.pointerHover(PointerHover(isInside: true)), seq: 7)
        #expect(await host.messages(count: 1, isPresent).count == 1)
        try host.send(.input(input: .click))

        let presents = await host.messages(count: 2, isPresent)
        #expect(presents == [
            .present(priority: .standard, peek: slot, wing: nil, expanded: nil, opensAt: .peek, seconds: nil,
                     dismissIfNotShown: true, accepts: nil, answering: 7),
            .present(priority: .standard, peek: slot, wing: nil, expanded: nil, opensAt: .peek, seconds: nil,
                     dismissIfNotShown: false, accepts: [.file], answering: nil),
        ])
        host.close()
    }

    @MainActor
    @Test func dropAndItemInputsReachHandlers() async throws {
        let seen = Seen()
        let host = FakeHost()
        host.run(TestBlock { ctx in
            ctx.onDrop { seen.drops.append($0) }
            ctx.onItem { seen.items.append(($0, $1)) }
            ctx.onInput { seen.inputs.append($0) }
        })
        try await host.welcome()

        let dropped: [WireDrop] = [.file(path: "/tmp/a.png"), .link(url: "https://example.com"), .text(string: "hi")]
        try host.drop(dropped)
        try host.item("tile-1", .click)
        try host.item("tile-1", .doubleClick)
        try host.item("tile-2", .menu(id: "remove"))
        try host.send(.input(input: .button(id: "go")))

        #expect(await eventually { seen.items.count == 3 && seen.inputs.count == 1 })
        #expect(seen.drops == [dropped])
        #expect(seen.items.map { $0.0 } == ["tile-1", "tile-1", "tile-2"])
        #expect(seen.items.map { $0.1 } == [.click, .doubleClick, .menu(id: "remove")])
        // Drops and item actions go to their own handlers only.
        #expect(seen.inputs == [.button(id: "go")])
        host.close()
    }

    @MainActor
    @Test func dragBeganThenDragEndedReachHandlersInOrder() async throws {
        let seen = Seen()
        let host = FakeHost()
        host.run(TestBlock { ctx in
            ctx.onDragBegan { seen.drags.append("began \($0)") }
            ctx.onDragEnded { id, succeeded in seen.drags.append("ended \(id) \(succeeded)") }
        })
        try await host.welcome()

        try host.dragBegan("tile-1")
        try host.dragEnded("tile-1", succeeded: true)
        try host.dragBegan("tile-2")
        try host.dragEnded("tile-2", succeeded: false)

        #expect(await eventually { seen.drags.count == 4 })
        #expect(seen.drags == ["began tile-1", "ended tile-1 true", "began tile-2", "ended tile-2 false"])
        host.close()
    }

    @MainActor
    @Test func previewAndSettingNoteAreSent() async throws {
        let host = FakeHost()
        host.run(TestBlock { ctx in
            ctx.preview(paths: ["/tmp/a.png", "/tmp/b.pdf"])
            ctx.setNote(key: "model", text: "Model ready")
        })
        try await host.welcome()

        #expect(await host.waitFor { if case .settingNote = $0 { true } else { false } } != nil)
        #expect(host.previews == [["/tmp/a.png", "/tmp/b.pdf"]])
        #expect(host.notes == [SettingNote(key: "model", text: "Model ready")])
        #expect(host.received.contains(.preview(paths: ["/tmp/a.png", "/tmp/b.pdf"])))
        host.close()
    }

    @MainActor
    @Test func versionOneBlockStillRuns() async throws {
        let seen = Seen()
        let slot = ViewSlot(width: 300, height: 40, root: .text("Hi"))
        let host = FakeHost()
        host.run(TestBlock(contract: 1) { ctx in
            ctx.on(.pointerHover) { event in
                seen.events.append(event)
                ctx.present(peek: slot, for: 2)
            }
        })

        let hello = await host.waitFor { if case .hello = $0 { true } else { false } }
        #expect(hello == .hello(contract: 1, id: "test", version: "1.0"))
        try await host.welcome()

        // A version 1 app sends events without `seq`.
        try host.send(hover)
        #expect(await eventually { seen.events.count == 1 })
        let presents = await host.messages(count: 1, isPresent)
        #expect(presents == [
            .present(priority: .standard, peek: slot, wing: nil, expanded: nil, opensAt: .peek, seconds: 2, dismissIfNotShown: false),
        ])
        #expect(host.streamError == nil)
        #expect(!host.received.contains { if case let .log(text) = $0 { text.contains("stopping") } else { false } })
        host.close()
    }
}

/// True when `task` ends within `timeout`.
func finishes(_ task: Task<Void, Never>, timeout: Duration = .seconds(2)) async -> Bool {
    let done = Flag()
    Task {
        await task.value
        done.set()
    }
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if done.isSet { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return done.isSet
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
