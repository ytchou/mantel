import BlockWire
import Darwin
import Foundation
import Network
import Testing
@testable import BlockHost

/// The real `FixtureBlock` executable over a real socket pair.
@Suite(.serialized)
struct ProcessTests {
    @Test func spawnedFixtureSaysHello() async throws {
        let package = try Fixture.package()
        let process = try BlockProcess.spawn(executable: Fixture.executable(in: package), generation: 7)
        defer { process.terminate() }

        var hello: Envelope<BlockToHost>?
        for try await envelope in process.envelopes(of: BlockToHost.self) {
            hello = envelope
            break
        }

        let first = try #require(hello)
        #expect(first.generation == 7, "the generation comes from MANTEL_BLOCK_GENERATION")
        #expect(first.message == .hello(contract: Contract.current, id: "fixture", version: "1.0.0"))

        // Without the socket the fixture exits, and it is reaped.
        process.terminate()
        #expect(process.hasExited)
        #expect(!processExists(process.pid))
    }

    /// A7: a child the block started does not outlive it.
    @Test func aChildProcessEndsWithTheBlock() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let process = try BlockProcess.spawn(executable: Fixture.executable(in: rig.package), generation: 1,
                                             sandbox: rig.profile())
        defer { process.terminate() }
        #expect(getpgid(process.pid) == process.pid, "the block leads a process group of its own")

        let logs = try await rig.talk(to: process, generation: 1, commands: ["spawn"]).logs
        let line = try #require(logs.first)
        let child = try #require(pid_t(line.dropFirst("spawned ".count)), "log: \(line)")
        #expect(processExists(child))

        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while processExists(child), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!processExists(child), "the child was ended with the block")
    }

    /// A8: an action waits for the process to exit, then runs once.
    @Test func whenExitedRunsAfterTheProcessExits() async throws {
        let package = try Fixture.package()
        let process = try BlockProcess.spawn(executable: Fixture.executable(in: package), generation: 1)
        defer { process.terminate() }
        let ran = Asked()

        process.whenExited { ran.add("exited") }
        #expect(ran.all.isEmpty, "still running")

        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while ran.all.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ran.all == ["exited"])
        process.whenExited { ran.add("late") }
        #expect(ran.all == ["exited", "late"], "after the exit, at once")
    }

    // MARK: Sandboxed

    @Test func sandboxedFixtureSaysHello() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let process = try BlockProcess.spawn(executable: Fixture.executable(in: rig.package), generation: 4,
                                             sandbox: rig.profile())
        defer { process.terminate() }

        let replies = try await rig.talk(to: process, generation: 4, commands: [])
        #expect(replies.hello == .hello(contract: Contract.current, id: "fixture", version: "1.0.0"))
        #expect(replies.ponged, "the fixture answered a ping after welcome")
    }

    @Test func fixtureWithoutNetworkCannotConnect() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let listener = try Listener()
        defer { listener.close() }

        let logs = try await rig.run(rig.profile(), ["connect:\(listener.port)"])
        #expect(logs == ["connect failed"])
    }

    // MARK: Network gate

    /// A block with hosts reaches its gate and nothing else on this Mac.
    @Test func fixtureCannotConnectDirectly() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let other = try Listener()
        defer { other.close() }
        let gate = NetworkGate(blockID: "fixture", hosts: ["api.example.test"], connector: { _, _ in
            Issue.record("no CONNECT was sent")
            return NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        })
        let port = try gate.start()
        defer { gate.stop() }

        let logs = try await rig.run(rig.profile(gatePort: port), ["connect:\(other.port)", "connect:\(port)"],
                                     gatePort: port)
        #expect(logs == ["connect failed", "connect ok"])
    }

    /// `fetch:` goes through the kit's session and the gate. The connector
    /// sends the approved host to a local TLS server, so nothing leaves this Mac.
    @Test func fixtureFetchesThroughTheGate() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let server = try LocalTLSServer(in: rig.root)
        defer { server.stop() }
        let asked = Asked()
        let serverPort = NWEndpoint.Port(rawValue: server.port)!
        let gate = NetworkGate(blockID: "fixture", hosts: ["api.example.test"], connector: { host, port in
            asked.add("\(host):\(port)")
            return NWConnection(host: "127.0.0.1", port: serverPort, using: .tcp)
        })
        let port = try gate.start()
        defer { gate.stop() }

        let logs = try await rig.run(rig.profile(gatePort: port), ["fetch:https://api.example.test/"], gatePort: port)
        #expect(logs == ["fetch ok"])
        #expect(asked.all == ["api.example.test:443"])
    }
    @Test func fixtureCannotWriteOutsideItsDataFolder() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let outside = rig.home.appending(path: "outside")
        let inside = rig.data.appending(path: "inside")
        let process = try BlockProcess.spawn(executable: Fixture.executable(in: rig.package), generation: 1,
                                             sandbox: rig.profile())
        defer { process.terminate() }

        let replies = try await rig.talk(to: process, generation: 1, commands: ["write:\(outside.path)", "write:\(inside.path)"])
        #expect(replies.logs == ["write failed", "write ok"])
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: inside.path))
    }

    /// Other blocks' files and dropped files sit in the app's `Mantel`
    /// temporary subtree: closed. The block's own temporary folder inside it is open.
    @Test func fixtureCannotReadTheAppTemporarySubtreeButUsesItsOwn() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let other = rig.shared.appending(path: "Mantel/Blocks/other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let shared = other.appending(path: "other-block-file")
        try Data("x".utf8).write(to: shared)
        let own = rig.temporary.appending(path: "own")
        let process = try BlockProcess.spawn(executable: Fixture.executable(in: rig.package), generation: 1,
                                             sandbox: rig.profile())
        defer { process.terminate() }

        let replies = try await rig.talk(to: process, generation: 1,
                                         commands: ["read:\(shared.path)", "write:\(own.path)", "read:\(own.path)"])
        #expect(replies.logs == ["read failed", "write ok", "read ok"])
        #expect(FileManager.default.fileExists(atPath: own.path))
    }

    // MARK: Read allow-list

    @Test func fixtureCannotReadAnotherBlocksData() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let other = rig.support.appending(path: "BlockData/other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let secret = other.appending(path: "secret")
        try Data("x".utf8).write(to: secret)

        for readsHome in [false, true] {
            let logs = try await rig.run(rig.profile(readsHome: readsHome), ["read:\(secret.path)"])
            #expect(logs == ["read failed"], "files.read: \(readsHome)")
        }
    }

    @Test func fixtureCannotReadTheAppsPreferencesFile() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        try FileManager.default.createDirectory(at: rig.preferencesFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: rig.preferencesFile)
        // Control: with files.read another file in the home folder reads.
        let note = rig.home.appending(path: "Documents/note")
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: note)

        let without = try await rig.run(rig.profile(), ["read:\(rig.preferencesFile.path)", "read:\(note.path)"])
        #expect(without == ["read failed", "read failed"])
        let with = try await rig.run(rig.profile(readsHome: true), ["read:\(rig.preferencesFile.path)", "read:\(note.path)"])
        #expect(with == ["read failed", "read ok"])
    }

    /// Through the preferences service, not the file: the app's domain reads
    /// nothing; another domain still reads (a written limit). The profile's
    /// home is the real one, as in the app: the preferences client needs
    /// metadata reads there, and without them every domain reads nothing,
    /// so the closed half would pass whatever the rule (probed 2026-11-21).
    @Test func fixtureCannotReadTheAppsPreferenceDomain() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let domain = "dev.mantel.tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set("x", forKey: "probe")
        CFPreferencesAppSynchronize(domain as CFString)
        defer { defaults.removePersistentDomain(forName: domain) }

        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let closed = try await rig.run(rig.profile(preferenceDomain: domain, home: home), ["prefs:\(domain)"])
        #expect(closed == ["prefs none"])
        let control = try await rig.run(rig.profile(preferenceDomain: "dev.mantel.unrelated", home: home), ["prefs:\(domain)"])
        #expect(control == ["prefs found"])
    }

    /// A file outside the home folder, the package and the system
    /// locations, and one in the shared temporary folder outside the block's own.
    @Test func fixtureCannotReadOutsideTheAllowList() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let outside = rig.root.appending(path: "outside/file")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside)
        let otherApp = rig.shared.appending(path: "other-app")
        try Data("x".utf8).write(to: otherApp)

        let logs = try await rig.run(rig.profile(), ["read:\(outside.path)", "read:\(otherApp.path)"])
        #expect(logs == ["read failed", "read failed"])
    }

    @Test func fixtureStillReadsItsOwnDataAndPackage() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let own = rig.data.appending(path: "own")
        try Data("x".utf8).write(to: own)
        let manifest = rig.package.appending(path: "Contents/Resources/manifest.json")

        for readsHome in [false, true] {
            let logs = try await rig.run(rig.profile(readsHome: readsHome), ["read:\(own.path)", "read:\(manifest.path)"])
            #expect(logs == ["read ok", "read ok"], "files.read: \(readsHome)")
        }
    }
}

// MARK: - Helpers

/// A fixture package and sibling "home", data and shared temporary folders
/// in one temporary root, so the data folder is not inside the "home"
/// folder. The block's temporary folder is inside the shared one's `Mantel`
/// subtree, as in the app.
private struct SandboxRig {
    let root: URL
    let package: URL
    let home: URL
    /// Mantel's support folder inside the "home" folder, as in the app.
    let support: URL
    let data: URL
    let shared: URL
    let temporary: URL
    var preferencesFile: URL { home.appending(path: "Library/Preferences/dev.mantel.MantelTests.plist") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "mantel-sandboxed-\(UUID().uuidString)")
        home = root.appending(path: "home")
        support = home.appending(path: "Library/Application Support/Mantel")
        data = support.appending(path: "BlockData/fixture")
        shared = root.appending(path: "shared-tmp")
        temporary = shared.appending(path: "Mantel/Blocks/fixture")
        for folder in [home, data, temporary] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        package = try Fixture.package()
    }

    func profile(gatePort: UInt16? = nil, readsHome: Bool = false,
                 preferenceDomain: String = "dev.mantel.MantelTests", home: URL? = nil) -> SandboxProfile {
        SandboxProfile(gatePort: gatePort, readsHome: readsHome, screenshotFolder: nil, package: package,
                       dataFolder: data, temporaryFolder: temporary, sharedTemporaryFolder: shared, home: home ?? self.home,
                       supportRoot: support, preferencesFile: preferencesFile, preferenceDomain: preferenceDomain)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: package.deletingLastPathComponent())
    }

    /// Starts the fixture under `profile`, runs `commands` and returns its log lines.
    func run(_ profile: SandboxProfile, _ commands: [String], gatePort: UInt16? = nil) async throws -> [String] {
        let process = try BlockProcess.spawn(executable: Fixture.executable(in: package), generation: 1, sandbox: profile)
        defer { process.terminate() }
        return try await talk(to: process, generation: 1, commands: commands, gatePort: gatePort).logs
    }

    struct Replies {
        var hello: BlockToHost?
        var ponged = false
        var logs: [String] = []
    }

    /// Reads `hello`, sends `welcome` with the first command, then a ping and
    /// each later command as a `setting`; collects the `log` lines until one
    /// per command arrived and the ping was answered.
    func talk(to process: BlockProcess, generation: Int, commands: [String], gatePort: UInt16? = nil) async throws -> Replies {
        let settings: [String: SettingValue] = commands.first.map { ["command": .string($0)] } ?? [:]
        let data = data
        let stream = process.envelopes(of: BlockToHost.self)
        let reader = Task { () throws -> Replies in
            var replies = Replies()
            var remaining = commands.dropFirst()
            for try await envelope in stream {
                switch envelope.message {
                case .hello:
                    replies.hello = envelope.message
                    try process.send(HostToBlock.welcome(contract: Contract.current, settings: settings, dataFolder: data.path,
                                                         gatePort: gatePort.map(Int.init)),
                                     generation: generation)
                    try process.send(HostToBlock.ping(seq: 1), generation: generation)
                case .pong:
                    replies.ponged = true
                case let .log(text):
                    replies.logs.append(text)
                    if let next = remaining.first {
                        remaining = remaining.dropFirst()
                        try process.send(HostToBlock.setting(key: "command", value: .string(next)), generation: generation)
                    }
                default:
                    break
                }
                if replies.ponged, replies.logs.count == commands.count { return replies }
            }
            return replies
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            reader.cancel()
            process.close()
        }
        defer { timeout.cancel() }
        return try await reader.value
    }
}

/// A TCP listener on 127.0.0.1 at a free port, opened by the test.
private final class Listener {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var actual = sockaddr_in()
        var length = size
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    func close() { Darwin.close(fd) }
}

/// The hosts a test connector was asked for, from any thread.
final class Asked: @unchecked Sendable {
    // @unchecked: `lock` guards `hosts`.
    private let lock = NSLock()
    private var hosts: [String] = []

    func add(_ host: String) { lock.withLock { hosts.append(host) } }
    var all: [String] { lock.withLock { hosts } }
}

/// `openssl s_server -www` on a free local port with a certificate it
/// signs itself: an HTTPS server on this Mac for the gate tests.
private final class LocalTLSServer {
    let port: UInt16
    private let process = Process()

    init(in folder: URL) throws {
        let key = folder.appending(path: "server-key.pem")
        let certificate = folder.appending(path: "server-cert.pem")
        let generate = Process()
        generate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        generate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1",
                              "-subj", "/CN=api.example.test", "-keyout", key.path, "-out", certificate.path]
        generate.standardOutput = FileHandle.nullDevice
        generate.standardError = FileHandle.nullDevice
        try generate.run()
        generate.waitUntilExit()
        guard generate.terminationStatus == 0 else { throw POSIXError(.EIO) }

        // A free port: bound once by the test, then given to the server.
        let probe = try Listener()
        port = probe.port
        probe.close()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["s_server", "-accept", String(port), "-cert", certificate.path, "-key", key.path,
                             "-www", "-quiet"]
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Ready once it accepts a connection.
        let deadline = Date().addingTimeInterval(5)
        while !Self.accepts(port) {
            guard Date() < deadline else {
                stop()
                throw POSIXError(.ETIMEDOUT)
            }
            usleep(50_000)
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private static func accepts(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }
}
