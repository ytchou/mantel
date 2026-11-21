import BlockWire
import Darwin
import Foundation
import Network
import Testing
@testable import BlockHost
import NotchCore

/// The gate over real local sockets. Its connector always leads to a
/// listener on this Mac: no test reaches the internet.
@Suite(.serialized)
struct NetworkGateTests {
    // MARK: Host rules

    @Test func anExactHostMatches() {
        let rule = HostRule("api.example.com")
        #expect(rule.matches("api.example.com"))
        #expect(rule.matches("API.Example.com"))
        #expect(!rule.matches("example.com"))
        #expect(!rule.matches("a.api.example.com"))
        #expect(!rule.matches("api.example.com.evil.test"))
        #expect(!rule.matches("xapi.example.com"))
    }

    @Test func aWildcardMatchesSubdomainsOnly() {
        let rule = HostRule("*.example.org")
        #expect(rule.matches("a.example.org"))
        #expect(rule.matches("a.b.example.org"))
        #expect(!rule.matches("example.org"))
        #expect(!rule.matches("badexample.org"))
        #expect(!rule.matches(".example.org"))
        #expect(!rule.matches("a.example.org.evil.test"))
    }

    @Test func hostProblemsAreNamed() {
        #expect(HostRule.problem(with: "api.example.com") == nil)
        #expect(HostRule.problem(with: "*.example.org") == nil)
        for bad in ["*", "", "*.com", "a*.example.org", "*example.org", "api..example.com", ".example.com",
                    "api.example.com:443", "https://api.example.com", "api example.com"] {
            #expect(HostRule.problem(with: bad) != nil, "\(bad)")
        }
    }

    // MARK: The gate

    @Test func theGatePassesConnectToAnApprovedHostOnPort443() async throws {
        let upstream = try LoopbackServer(reply: Data("pong".utf8), expecting: 4)
        defer { upstream.close() }
        let asked = Asked()
        let upstreamPort = NWEndpoint.Port(rawValue: upstream.port)!
        let gate = NetworkGate(blockID: "test", hosts: ["api.example.com", "*.example.org"], connector: { host, port in
            asked.add("\(host):\(port)")
            return NWConnection(host: "127.0.0.1", port: upstreamPort, using: .tcp)
        })
        let port = try gate.start()
        defer { gate.stop() }

        for host in ["api.example.com", "a.b.example.org"] {
            let client = try LoopbackClient(port: port)
            defer { client.close() }
            try client.write("CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n")
            let head = try client.readHead()
            #expect(head.hasPrefix("HTTP/1.1 200"), "\(host): \(head)")
            try client.write("ping")
            #expect(try client.read(count: 4) == Data("pong".utf8))
            #expect(upstream.nextReceived() == Data("ping".utf8))
        }
        #expect(asked.all == ["api.example.com:443", "a.b.example.org:443"])
    }

    @Test func theGateRefusesAnotherHostAnotherPortAndPlainHTTP() async throws {
        let asked = Asked()
        let gate = NetworkGate(blockID: "test", hosts: ["api.example.com"], connector: { host, port in
            asked.add("\(host):\(port)")
            return NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        })
        let port = try gate.start()
        defer { gate.stop() }

        let requests = [
            "CONNECT other.example.com:443 HTTP/1.1\r\nHost: other.example.com:443\r\n\r\n",
            "CONNECT api.example.com:80 HTTP/1.1\r\nHost: api.example.com:80\r\n\r\n",
            "GET http://api.example.com/ HTTP/1.1\r\nHost: api.example.com\r\n\r\n",
            "CONNECT example.com:443 HTTP/1.1\r\n\r\n",
        ]
        for request in requests {
            let client = try LoopbackClient(port: port)
            defer { client.close() }
            try client.write(request)
            let head = try client.readHead()
            #expect(head.hasPrefix("HTTP/1.1 403"), "\(request): \(head)")
        }
        #expect(asked.all.isEmpty)
    }

    @Test func theGateParsesOnlyConnect() {
        let target = NetworkGate.connectTarget(Data("CONNECT Api.Example.com:443 HTTP/1.1".utf8))
        #expect(target?.host == "api.example.com")
        #expect(target?.port == 443)
        #expect(NetworkGate.connectTarget(Data("GET / HTTP/1.1".utf8)) == nil)
        #expect(NetworkGate.connectTarget(Data("CONNECT api.example.com HTTP/1.1".utf8)) == nil)
        #expect(NetworkGate.connectTarget(Data("CONNECT :443 HTTP/1.1".utf8)) == nil)
        #expect(NetworkGate.connectTarget(Data("CONNECT api.example.com:443".utf8)) == nil)
    }

    // MARK: The stand-in

    @MainActor
    @Test func aBlockWithoutNetworkGetsNoGate() async throws {
        let rig = Rig()
        try await rig.process.start()
        #expect(rig.block.gate == nil)
        #expect(rig.block.gatePort == nil)
        #expect(welcomePort(rig.process.received) == .some(nil))
    }

    @MainActor
    @Test func aBlockWithHostsGetsItsGatePortInWelcome() async throws {
        var manifest = helloManifest
        manifest.access = [.network]
        manifest.hosts = ["api.example.com"]
        let rig = Rig(manifest: manifest)
        try await rig.process.start()
        let port = try #require(rig.block.gatePort)
        #expect(rig.block.gate != nil)
        #expect(welcomePort(rig.process.received) == .some(Int(port)))

        // The gate listens while the block runs, and closes with it.
        let client = try LoopbackClient(port: port)
        client.close()
        rig.block.stop()
        #expect(rig.block.gate == nil)
        #expect(rig.block.gatePort == nil)
    }

    /// A gate that cannot open: the block starts without network, and the
    /// reason is published for the Blocks page, then cleared once the gate
    /// opens at a later start.
    @MainActor
    @Test func aGateThatCannotOpenPublishesTheReason() async throws {
        var manifest = helloManifest
        manifest.access = [.network]
        manifest.hosts = ["api.example.com"]
        let runtime = NotchRuntime()
        let launcher = FakeLauncher()
        let block = Rig.standIn(manifest: manifest, runtime: runtime, launcher: launcher, defaults: testDefaults())
        block.startGate = { _ in throw NetworkGateError.failed("no port") }
        runtime.register(block)
        defer { block.stop() }
        try await launcher.last!.start()

        let notice = try #require(block.notice)
        #expect(notice.contains("without network"))
        #expect(notice.contains("no port"))
        #expect(block.health == .ok, "not a failure: the block runs")
        #expect(block.gatePort == nil)
        #expect(welcomePort(launcher.last!.received) == .some(nil))

        block.startGate = { try $0.start() }
        runtime.setEnabled(block.id, false)
        runtime.setEnabled(block.id, true)
        #expect(block.notice == nil)
        #expect(block.gatePort != nil)
    }

    /// The gate port the first `welcome` carried; nil when none was sent.
    private func welcomePort(_ messages: [HostToBlock]) -> Int?? {
        for message in messages {
            if case let .welcome(_, _, _, gatePort) = message { return .some(gatePort) }
        }
        return nil
    }
}

// MARK: - Helpers

/// A listener on 127.0.0.1 at a free port that accepts connections one
/// after another; for each it reads `expecting` bytes, keeps them for
/// `nextReceived()` and writes `reply`.
final class LoopbackServer: @unchecked Sendable {
    // @unchecked: `lock` guards `received`; `fd` does not change.
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var received: [Data] = []
    private let arrived = DispatchSemaphore(value: 0)

    init(reply: Data, expecting: Int) throws {
        (fd, port) = try boundLoopbackSocket()
        Thread.detachNewThread { [self] in
            while true {
                let connection = Darwin.accept(fd, nil, nil)
                guard connection >= 0 else { return }
                setTimeout(connection)
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: expecting)
                while bytes.count < expecting {
                    let count = Darwin.read(connection, &buffer, expecting - bytes.count)
                    guard count > 0 else { break }
                    bytes.append(contentsOf: buffer[..<count])
                }
                lock.withLock { received.append(bytes) }
                arrived.signal()
                _ = reply.withUnsafeBytes { Darwin.write(connection, $0.baseAddress, reply.count) }
                Darwin.close(connection)
            }
        }
    }

    /// What the next connection sent, waiting up to 5 s.
    func nextReceived() -> Data? {
        guard arrived.wait(timeout: .now() + 5) == .success else { return nil }
        return lock.withLock { received.removeFirst() }
    }

    func close() {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

/// A blocking TCP client to 127.0.0.1, with 5 s timeouts.
final class LoopbackClient {
    private let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        setTimeout(fd)
        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
    }

    func write(_ text: String) throws {
        let data = Data(text.utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw POSIXError(.EIO) }
    }

    /// Up to and including the blank line that ends a response header, as text.
    func readHead() throws -> String {
        var bytes = Data()
        var byte: UInt8 = 0
        while !bytes.ends(with: Data("\r\n\r\n".utf8)) {
            guard Darwin.read(fd, &byte, 1) == 1 else { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func read(count: Int) throws -> Data {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while bytes.count < count {
            let read = Darwin.read(fd, &buffer, count - bytes.count)
            guard read > 0 else { throw POSIXError(.EIO) }
            bytes.append(contentsOf: buffer[..<read])
        }
        return bytes
    }

    func close() { Darwin.close(fd) }
}

private extension Data {
    func ends(with suffix: Data) -> Bool {
        count >= suffix.count && self[(endIndex - suffix.count)...] == suffix
    }
}

private func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}

private func setTimeout(_ fd: Int32) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
}

/// A listening socket on 127.0.0.1 at a port the system picks.
private func boundLoopbackSocket() throws -> (Int32, UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = loopbackAddress(port: 0)
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }
    guard bound == 0, listen(fd, 8) == 0 else {
        Darwin.close(fd)
        throw POSIXError(.EADDRINUSE)
    }
    var actual = sockaddr_in()
    var length = size
    _ = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return (fd, UInt16(bigEndian: actual.sin_port))
}
