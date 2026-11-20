import Foundation
import Testing
@testable import BlockKit
import BlockKitTesting

/// A block whose `start` is supplied by the test.
struct TestBlock: Block {
    let id: String
    let version: String
    let onStart: @MainActor (Context) -> Void

    init() { self.init { _ in } }

    init(id: String = "test", version: String = "1.0", _ onStart: @escaping @MainActor (Context) -> Void) {
        self.id = id
        self.version = version
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
        #expect(envelopes.first == Envelope(generation: host.generation, message: .hello(contract: 1, id: "hello", version: "2.1")))
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
