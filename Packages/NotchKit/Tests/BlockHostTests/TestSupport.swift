import BlockWire
import Foundation
import SwiftUI
import Synchronization
@testable import BlockHost
import NotchCore

// MARK: - A block process played by the test

/// The block's end of one in-memory connection. Records what the app sends
/// and sends frames as the block would.
final class FakeProcess: @unchecked Sendable {
    // @unchecked: `lock` guards `frames`.
    let generation: Int
    let executable: URL
    private let transport: MemoryTransport
    /// The app's end, to deliver bytes the block never could have framed.
    private let appEnd: MemoryTransport?
    private let lock = NSLock()
    private var frames: [Envelope<HostToBlock>] = []

    init(transport: MemoryTransport, executable: URL, generation: Int, appEnd: MemoryTransport? = nil) {
        self.transport = transport
        self.appEnd = appEnd
        self.executable = executable
        self.generation = generation
        let stream = transport.envelopes(of: HostToBlock.self)
        Task { [weak self] in
            for try await envelope in stream {
                self?.lock.withLock { self?.frames.append(envelope) }
            }
        }
    }

    /// Every message the app has sent to this process, in order.
    var received: [HostToBlock] { lock.withLock { frames.map(\.message) } }

    /// Sends a message in this process's generation, or in `generation`.
    func send(_ message: BlockToHost, generation: Int? = nil) throws {
        try transport.send(message, generation: generation ?? self.generation)
    }

    func hello(contract: Int = Contract.current) throws {
        try send(.hello(contract: contract, id: "hello", version: "1.0.0"))
    }

    /// Says hello and waits for the app's `welcome`.
    func start() async throws {
        try hello()
        _ = await waitFor { if case .welcome = $0 { true } else { false } }
    }

    func close() { transport.close() }

    /// Bytes that are not a frame, as a broken block would send.
    func sendGarbage() { appEnd?.injectReceived(Data("not json".utf8)) }

    /// Answers the latest `ping` received.
    func answerLatestPing() throws {
        let seq = received.compactMap { if case let .ping(seq) = $0 { seq } else { nil } }.last
        if let seq { try send(.pong(seq: seq)) }
    }

    func waitFor(timeout: Duration = .seconds(2), _ match: @Sendable (HostToBlock) -> Bool) async -> HostToBlock? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            if let found = received.first(where: match) { return found }
            if clock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The `seq` of each `event` message received so far, nil for none.
    var eventSeqs: [Int?] {
        received.compactMap { message -> Int?? in
            if case let .event(_, _, seq) = message { return .some(seq) }
            return nil
        }
    }

    /// The `input` messages received so far.
    var inputs: [WireInput] {
        received.compactMap { if case let .input(input) = $0 { input } else { nil } }
    }

    /// The `event` messages received so far.
    var events: [(payload: EventPayload, replay: Bool)] {
        received.compactMap { if case let .event(payload, replay, _) = $0 { (payload, replay) } else { nil } }
    }
}

/// Plays the launcher: each launch makes a new in-memory connection.
@MainActor
final class FakeLauncher {
    private(set) var processes: [FakeProcess] = []

    var launcher: BlockLauncher {
        { [unowned self] executable, generation in
            let (app, block) = MemoryTransport.pair()
            processes.append(FakeProcess(transport: block, executable: executable, generation: generation, appEnd: app))
            return app
        }
    }

    var last: FakeProcess? { processes.last }
}

// MARK: - Building stand-ins

let helloManifest = Manifest(
    id: "hello",
    name: "Hello",
    version: "1.0.0",
    executable: "HelloBlock",
    summary: "Says hello.",
    symbol: "hand.wave",
    trigger: "Pointer hover",
    events: ["pointerHover", "outputVolume", "nowPlaying"],
    settings: [
        SettingSpec(key: "loud", type: .toggle, title: "Loud", default: .bool(false)),
        SettingSpec(key: "size", type: .choice, title: "Size", default: .string("large"),
                    options: [.init(value: "large", title: "Large")]),
        SettingSpec(key: "about", type: .note, title: "A note"),
    ]
)

/// The ids the turn-off closure was called with.
@MainActor
final class TurnOffs {
    var ids: [BlockID] = []
}

/// A fresh, empty settings store for one test.
func testDefaults() -> UserDefaults {
    UserDefaults(suiteName: "BlockHostTests.\(UUID().uuidString)")!
}

/// A stand-in registered in `runtime`, with its launcher. Its settings live
/// in `defaults`, and its heartbeat and failure times on `heartbeat`, which
/// moves only when a test advances it (as a suspending clock does not move
/// while the Mac sleeps). Turning off is recorded in `turnOffs` and applied
/// to the runtime, as the app's closure does through `BlockSettings`.
@MainActor
struct Rig {
    let runtime: NotchRuntime
    let block: RemoteBlock
    let launcher: FakeLauncher
    let defaults: UserDefaults
    let heartbeat: ManualClock
    let turnOffs = TurnOffs()
    var process: FakeProcess { launcher.last! }

    init(
        clock: ManualClock = ManualClock(), manifest: Manifest = helloManifest, defaults: UserDefaults = testDefaults(),
        preview: @escaping @MainActor ([URL]) -> Void = { _ in }
    ) {
        runtime = NotchRuntime(clock: clock)
        launcher = FakeLauncher()
        self.defaults = defaults
        heartbeat = ManualClock()
        block = Self.standIn(manifest: manifest, runtime: runtime, launcher: launcher, defaults: defaults,
                             heartbeat: heartbeat, turnOffs: turnOffs, preview: preview)
        runtime.register(block)
    }

    /// A stand-in wired like the rig's, not registered.
    static func standIn(
        manifest: Manifest = helloManifest, runtime: NotchRuntime, launcher: FakeLauncher,
        defaults: UserDefaults, heartbeat: ManualClock = ManualClock(), turnOffs: TurnOffs = TurnOffs(),
        screenshotFolder: @escaping @MainActor () -> URL? = { nil },
        preview: @escaping @MainActor ([URL]) -> Void = { _ in }
    ) -> RemoteBlock {
        RemoteBlock(
            manifest: manifest,
            packageURL: URL(fileURLWithPath: "/tmp/Hello.topblock"),
            source: .development(path: "/tmp/Hello.topblock"),
            dataFolder: FileManager.default.temporaryDirectory.appending(path: "topnotch-tests-\(UUID().uuidString)"),
            owner: { runtime.state.owner },
            launcher: launcher.launcher,
            screenshotFolder: screenshotFolder,
            defaults: defaults,
            clock: BlockClock(heartbeat),
            turnOff: { id in
                turnOffs.ids.append(id)
                runtime.setEnabled(id, false)
            },
            preview: preview
        )
    }

    /// Lets the heartbeat take `count` steps of one second each.
    func beat(_ count: Int = 1) async {
        for _ in 0..<count {
            await waitUntil { heartbeat.sleeperCount > 0 }
            heartbeat.advance(by: .seconds(1))
            await settle()
        }
    }
}

func slot(_ root: ViewNode = .text("Hi", style: .title), width: Double = 380, height: Double = 52) -> ViewSlot {
    ViewSlot(width: width, height: height, root: root)
}

func present(
    _ root: ViewNode = .text("Hi", style: .title),
    priority: Priority = .standard,
    seconds: Double? = 3,
    dismissIfNotShown: Bool = false,
    accepts: [DragStarted.Kind]? = nil,
    answering: Int? = nil
) -> BlockToHost {
    .present(priority: priority, peek: slot(root), wing: nil, expanded: nil, opensAt: .peek,
             seconds: seconds, dismissIfNotShown: dismissIfNotShown, accepts: accepts, answering: answering)
}

// MARK: - Another block in the same runtime

@MainActor
final class OtherBlock: NotchBlock {
    let id: BlockID = "other"
    let title = "Other"
    private(set) var context: (any BlockContext)?

    func activate(_ context: any BlockContext) { self.context = context }

    func show(_ priority: PresentationPriority) {
        context?.present(Presentation(priority: priority, peek: NotchContent(size: CGSize(width: 10, height: 10)) { EmptyView() }))
    }
}

// MARK: - Waiting

/// Lets the main actor run until `condition` holds or about two seconds pass.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// Lets queued main-actor work run, for checks that something did not happen.
@MainActor
func settle() async {
    for _ in 0..<25 { try? await Task.sleep(for: .milliseconds(2)) }
}

// MARK: - Clock

/// A clock that moves only when told to.
final class ManualClock: Clock, Sendable {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        typealias Duration = Swift.Duration
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private enum Outcome { case wait, ready, cancelled }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { s -> Outcome in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= s.now { return .ready }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .ready: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = s.now.advanced(by: duration)
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }
            s.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

// MARK: - Packages

/// Writes a `.topblock` bundle at `folder`: `manifest` in `Contents/Resources`
/// and the executable in `Contents/MacOS`, copied from `executable` or, when
/// nil, a small shell script with `mode`. Returns `Contents/MacOS`.
@discardableResult
func writeBundle(
    at folder: URL, manifest: Manifest, executable: URL? = nil, writeExecutable: Bool = true, mode: Int = 0o755
) throws -> URL {
    let resources = folder.appending(path: "Contents/Resources")
    let macOS = folder.appending(path: "Contents/MacOS")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try Framing.encoder().encode(manifest).write(to: resources.appending(path: "manifest.json"))
    guard writeExecutable else { return macOS }
    let target = macOS.appending(path: manifest.executable)
    if let executable {
        try FileManager.default.copyItem(at: executable, to: target)
    } else {
        try Data("#!/bin/sh\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
    }
    return macOS
}

/// The manifest of a bundle written by `writeBundle`.
func bundleManifest(_ folder: URL) throws -> Manifest {
    try Manifest.decode(Data(contentsOf: folder.appending(path: "Contents/Resources/manifest.json")))
}

/// Signature results set by the test, the same for every package, except
/// for results queued with `queue`, used first, one per check.
final class FakeSignatures: SignatureChecking, @unchecked Sendable {
    // @unchecked: `lock` guards `result` and `queued`.
    private let lock = NSLock()
    private var result: PackageSignature
    private var queued: [PackageSignature] = []

    static let signer = "Test Signer"

    init(_ result: PackageSignature = .valid(signer: FakeSignatures.signer, teamID: "")) {
        self.result = result
    }

    func set(_ result: PackageSignature) { lock.withLock { self.result = result } }

    /// Results for the next checks, in order; then `result` again.
    func queue(_ results: [PackageSignature]) { lock.withLock { queued += results } }

    func check(_ bundle: URL) -> PackageSignature {
        lock.withLock { queued.isEmpty ? result : queued.removeFirst() }
    }
}

// MARK: - The fixture block executable

/// Builds `.topblock` folders around the `FixtureBlock` executable that
/// `swift build` puts next to the test bundle.
enum Fixture {
    private final class Marker {}

    /// The built `FixtureBlock`. `TOPNOTCH_FIXTURE_BLOCK` overrides the path.
    static var executable: URL? {
        if let path = ProcessInfo.processInfo.environment["TOPNOTCH_FIXTURE_BLOCK"] {
            return URL(fileURLWithPath: path)
        }
        // The test bundle sits in the build products folder, e.g.
        // .build/arm64-apple-macosx/debug/NotchKitPackageTests.xctest.
        let products = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
        let url = products.appending(path: "FixtureBlock")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static let manifest = Manifest(id: "fixture", name: "Fixture", version: "1.0.0", executable: "FixtureBlock",
                                   events: ["pointerHover"],
                                   settings: [SettingSpec(key: "command", type: .choice, title: "Test command", default: .string("none"),
                                                          options: ["none", "crash", "hang", "ignorePing"].map { .init(value: $0, title: $0) })])

    /// A temporary `Fixture.topblock` bundle with a copy of the built
    /// executable in `Contents/MacOS`. A copy, not a link: under the
    /// sandbox the block reads only its own package, and the build folder
    /// may be inside the home folder.
    static func package(_ manifest: Manifest = Fixture.manifest) throws -> URL {
        guard let executable else { throw FixtureMissing() }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "topnotch-fixture-\(UUID().uuidString)")
            .appending(path: "Fixture.topblock")
        try writeBundle(at: folder, manifest: manifest, executable: executable)
        return folder
    }

    /// The executable inside a package made by `package()`.
    static func executable(in package: URL) -> URL {
        package.appending(path: "Contents/MacOS/FixtureBlock")
    }

    struct FixtureMissing: Error, CustomStringConvertible {
        var description: String {
            "FixtureBlock was not found next to the test bundle. Run the tests with `make test`, or set TOPNOTCH_FIXTURE_BLOCK to the built executable."
        }
    }
}

/// True while a process with this id exists (running or not yet reaped).
func processExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}
