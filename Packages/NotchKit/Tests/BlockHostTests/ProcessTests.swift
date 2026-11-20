import BlockWire
import Darwin
import Foundation
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
        #expect(first.generation == 7, "the generation comes from TOPNOTCH_BLOCK_GENERATION")
        #expect(first.message == .hello(contract: Contract.current, id: "fixture", version: "1.0.0"))

        // Without the socket the fixture exits, and it is reaped.
        process.terminate()
        #expect(process.hasExited)
        #expect(!processExists(process.pid))
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
        let process = try BlockProcess.spawn(executable: Fixture.executable(in: rig.package), generation: 1,
                                             sandbox: rig.profile())
        defer { process.terminate() }

        let replies = try await rig.talk(to: process, generation: 1, commands: ["connect:\(listener.port)"])
        #expect(replies.logs == ["connect failed"])
    }

    @Test func fixtureWithNetworkCanConnect() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let listener = try Listener()
        defer { listener.close() }
        let process = try BlockProcess.spawn(executable: Fixture.executable(in: rig.package), generation: 1,
                                             sandbox: rig.profile(network: true))
        defer { process.terminate() }

        let replies = try await rig.talk(to: process, generation: 1, commands: ["connect:\(listener.port)"])
        #expect(replies.logs == ["connect ok"])
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

    /// Other blocks' files and dropped files sit in the app's `TopNotch`
    /// temporary subtree: closed. The block's own temporary folder inside it is open.
    @Test func fixtureCannotReadTheAppTemporarySubtreeButUsesItsOwn() async throws {
        let rig = try SandboxRig()
        defer { rig.remove() }
        let other = rig.shared.appending(path: "TopNotch/Blocks/other")
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
}

// MARK: - Helpers

/// A fixture package and sibling "home", data and shared temporary folders
/// in one temporary root, so the data folder is not inside the "home"
/// folder. The block's temporary folder is inside the shared one's `TopNotch`
/// subtree, as in the app.
private struct SandboxRig {
    let root: URL
    let package: URL
    let home: URL
    let data: URL
    let shared: URL
    let temporary: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "topnotch-sandboxed-\(UUID().uuidString)")
        home = root.appending(path: "home")
        data = root.appending(path: "data")
        shared = root.appending(path: "shared-tmp")
        temporary = shared.appending(path: "TopNotch/Blocks/fixture")
        for folder in [home, data, temporary] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        package = try Fixture.package()
    }

    func profile(network: Bool = false) -> SandboxProfile {
        SandboxProfile(network: network, readsHome: false, screenshotFolder: nil, package: package,
                       dataFolder: data, temporaryFolder: temporary, sharedTemporaryFolder: shared, home: home)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: package.deletingLastPathComponent())
    }

    struct Replies {
        var hello: BlockToHost?
        var ponged = false
        var logs: [String] = []
    }

    /// Reads `hello`, sends `welcome` with the first command, then a ping and
    /// each later command as a `setting`; collects the `log` lines until one
    /// per command arrived and the ping was answered.
    func talk(to process: BlockProcess, generation: Int, commands: [String]) async throws -> Replies {
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
                    try process.send(HostToBlock.welcome(contract: Contract.current, settings: settings, dataFolder: data.path),
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
