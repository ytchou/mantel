import Foundation
import Network
import os

/// One entry of a manifest's `hosts`: an exact host name, such as
/// `api.example.com`, or `*.` and a domain, such as `*.example.org`, which
/// matches every name below that domain but not the domain itself.
struct HostRule: Sendable, Equatable {
    /// Lowercased.
    let pattern: String

    init(_ pattern: String) {
        self.pattern = pattern.lowercased()
    }

    /// False for anything that is not a host name (`isHostName`), whatever
    /// the rule: a NUL, `/`, `%` or `_` before an approved suffix must not
    /// pass, since the connector may read only the part before it.
    func matches(_ host: String) -> Bool {
        let host = host.lowercased()
        guard Self.isHostName(host) else { return false }
        guard pattern.hasPrefix("*.") else { return host == pattern }
        // ".example.org": at least one character must come before it.
        let suffix = pattern.dropFirst()
        return host.count > suffix.count && host.hasSuffix(suffix)
    }

    /// Why `pattern` cannot be a host rule, as the end of the owner's
    /// refusal text, or nil when it can.
    static func problem(with pattern: String) -> String? {
        if pattern == "*" { return "\"*\" would let it reach every host" }
        let wildcard = pattern.hasPrefix("*.")
        let name = wildcard ? String(pattern.dropFirst(2)) : pattern
        guard isHostName(name.lowercased()) else { return "\"\(pattern)\" is not a host name" }
        // "*.com" names every host under a top-level domain.
        if wildcard, !name.contains(".") { return "\"\(pattern)\" would let it reach every host under \"\(name)\"" }
        return nil
    }

    /// True when `name` is lowercase letters, digits, `-` and `.` only, in
    /// labels that are not empty, and at most 253 characters: a host name
    /// or an IPv4 address. An IPv6 address never is.
    static func isHostName(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        return !name.isEmpty && name.count <= 253 && name.allSatisfy(allowed.contains)
            && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
    }
}

/// Why the gate did not open.
enum NetworkGateError: Error, CustomStringConvertible {
    case failed(String)
    case timedOut

    var description: String {
        switch self {
        case let .failed(detail): "the network gate could not open a local port (\(detail))"
        case .timedOut: "the network gate could not open a local port in time"
        }
    }
}

/// The only way a block with `hosts` reaches the network: a local HTTPS
/// proxy on `127.0.0.1`, at a port the system picks, one per running block.
/// The block's sandbox allows that port and nothing else. The gate accepts
/// `CONNECT <host>:443` for a host that matches one of the block's rules,
/// opens the connection itself (so the block needs no name lookups) and
/// passes bytes both ways. Anything else (another host, another port, plain
/// HTTP, a host that is not a host name, a header that never ends) gets
/// `403` and is closed. Each refused host is logged once, cut to
/// `loggedHostLength` characters and never with the request's content; past
/// `refusedLogLimit` different ones, one line says more are not logged.
///
/// Every mutable property is used on `queue` only.
final class NetworkGate: @unchecked Sendable {
    /// Opens the connection to an approved host. Tests point it at a local
    /// listener, so no test reaches the internet.
    typealias Connector = @Sendable (_ host: String, _ port: UInt16) -> NWConnection

    /// The real destination, by name: Network framework resolves it.
    static let direct: Connector = { host, port in
        NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .https, using: .tcp)
    }

    /// Only HTTPS passes.
    static let allowedPort: UInt16 = 443
    /// The most a request header may be before the gate gives up on it.
    static let headerLimit = 8192
    static let refusal = Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    static let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
    static let unreachable = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    /// The most different refusals a gate remembers and logs: the text is
    /// the block's, so neither memory nor the log may grow without end.
    static let refusedLogLimit = 64
    /// The most characters of a refused host that are logged: a host name's limit.
    static let loggedHostLength = 253

    let blockID: String
    let rules: [HostRule]
    private let connector: Connector
    private let queue: DispatchQueue
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "gate")

    private var listener: NWListener?
    /// Every connection the gate holds, from either side, until it ends.
    private var open: [ObjectIdentifier: NWConnection] = [:]
    /// Hosts already logged as refused, at most `refusedLogLimit`.
    private var refused: Set<String> = []
    /// True once the line saying more refusals are not logged was written.
    private var refusalsCapped = false

    init(blockID: String, hosts: [String], connector: @escaping Connector = NetworkGate.direct) {
        self.blockID = blockID
        rules = hosts.map(HostRule.init)
        self.connector = connector
        queue = DispatchQueue(label: "dev.topnotch.gate.\(blockID)")
    }

    func allows(_ host: String) -> Bool {
        rules.contains { $0.matches(host) }
    }

    /// The refusals logged so far. For tests.
    var refusedHosts: Set<String> { queue.sync { refused } }

    /// Opens the listener and returns its port.
    // Waits on the caller's thread, the main actor in the app, for the
    // listener to be ready: a local bind, well under a millisecond, capped
    // by `timeout`. If launches ever need to stay off the main actor
    // entirely, make `RemoteBlock.launch` async and await the ready state.
    func start(timeout: DispatchTimeInterval = .seconds(2)) throws(NetworkGateError) -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .failed("\(error)")
        }
        let ready = DispatchSemaphore(value: 0)
        let outcome = OSAllocatedUnfairLock<Result<UInt16, NetworkGateError>?>(initialState: nil)
        listener.stateUpdateHandler = { [weak listener] state in
            let result: Result<UInt16, NetworkGateError>
            switch state {
            case .ready:
                guard let port = listener?.port?.rawValue else { return }
                result = .success(port)
            case let .failed(error), let .waiting(error):
                result = .failure(.failed("\(error)"))
            case .cancelled:
                result = .failure(.failed("cancelled"))
            default:
                return
            }
            let first = outcome.withLock { current -> Bool in
                guard current == nil else { return false }
                current = result
                return true
            }
            if first { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
        let waited = ready.wait(timeout: .now() + timeout)
        let result = outcome.withLock { $0 }
        switch (waited, result) {
        case (.success, .success(let port)?):
            return port
        case (.success, .failure(let error)?):
            stop()
            throw error
        default:
            stop()
            throw .timedOut
        }
    }

    /// Closes the listener and every connection through it.
    func stop() {
        queue.async { [self] in
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            for connection in open.values { connection.cancel() }
            open = [:]
        }
    }

    // MARK: Connections (on `queue`)

    private func track(_ connection: NWConnection) {
        open[ObjectIdentifier(connection)] = connection
    }

    private func forget(_ connection: NWConnection) {
        open[ObjectIdentifier(connection)] = nil
    }

    private func accept(_ client: NWConnection) {
        guard listener != nil else { return client.cancel() }
        track(client)
        client.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled: forget(client)
            default: break
            }
        }
        client.start(queue: queue)
        readHeader(from: client, buffer: Data())
    }

    private func readHeader(from client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.headerLimit) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                handle(head: Data(buffer[..<end.lowerBound]), early: Data(buffer[end.upperBound...]), client: client)
            } else if buffer.count >= Self.headerLimit {
                refuse(client, naming: "a request whose header is too long")
            } else if isComplete || error != nil {
                client.cancel()
            } else {
                readHeader(from: client, buffer: buffer)
            }
        }
    }

    /// `head` is the request line and headers, without the blank line;
    /// `early` what the client sent after them, for the destination.
    private func handle(head: Data, early: Data, client: NWConnection) {
        guard let target = Self.connectTarget(head) else {
            return refuse(client, naming: "a request that is not CONNECT")
        }
        guard target.port == Self.allowedPort, allows(target.host) else {
            return refuse(client, naming: "\(target.host):\(target.port)")
        }
        tunnel(client, to: connector(target.host, target.port), early: early)
    }

    /// The host and port of `CONNECT <host>:<port> HTTP/1.x`, or nil for
    /// any other request.
    static func connectTarget(_ head: Data) -> (host: String, port: UInt16)? {
        guard let text = String(data: head, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "CONNECT", parts[2].hasPrefix("HTTP/1.") else { return nil }
        let authority = parts[1]
        guard let colon = authority.lastIndex(of: ":"),
              let port = UInt16(authority[authority.index(after: colon)...])
        else { return nil }
        let host = String(authority[..<colon]).lowercased()
        return host.isEmpty ? nil : (host, port)
    }

    private func refuse(_ client: NWConnection, naming host: String) {
        let host = String(host.prefix(Self.loggedHostLength))
        if refused.count < Self.refusedLogLimit {
            if refused.insert(host).inserted {
                log.info("\(self.blockID, privacy: .public): the gate refused \(host, privacy: .public)")
            }
        } else if !refused.contains(host), !refusalsCapped {
            refusalsCapped = true
            log.info("\(self.blockID, privacy: .public): the gate refused more hosts; they are not logged")
        }
        client.send(content: Self.refusal, completion: .contentProcessed { _ in client.cancel() })
    }

    private func tunnel(_ client: NWConnection, to upstream: NWConnection, early: Data) {
        let tunnel = Tunnel(client: client, upstream: upstream)
        track(upstream)
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !tunnel.started, !tunnel.closed else { return }
                tunnel.started = true
                client.send(content: Self.established, completion: .contentProcessed { _ in })
                if !early.isEmpty { upstream.send(content: early, completion: .contentProcessed { _ in }) }
                pump(from: client, to: upstream, in: tunnel)
                pump(from: upstream, to: client, in: tunnel)
            case .waiting, .failed:
                // Unreachable or refused by the destination: no retry.
                guard !tunnel.started, !tunnel.closed else { return tunnel.close() }
                tunnel.closed = true
                client.send(content: Self.unreachable, completion: .contentProcessed { _ in
                    client.cancel()
                    upstream.cancel()
                })
            case .cancelled:
                forget(upstream)
                tunnel.close()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// Passes what `source` sends on to `target`, one read at a time: the
    /// next read starts once the last one was handed over.
    private func pump(from source: NWConnection, to target: NWConnection, in tunnel: Tunnel) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !tunnel.closed else { return }
            let next: @Sendable () -> Void = { [weak self] in
                guard let self, !tunnel.closed else { return }
                if error != nil { return tunnel.close() }
                if isComplete {
                    // The source is done sending; the other direction goes on.
                    target.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in })
                    tunnel.finished += 1
                    if tunnel.finished == 2 { tunnel.close() }
                    return
                }
                pump(from: source, to: target, in: tunnel)
            }
            if let data, !data.isEmpty {
                target.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { tunnel.close() } else { next() }
                })
            } else {
                next()
            }
        }
    }

    /// The two sides of one approved CONNECT. Used on the gate's queue only.
    private final class Tunnel: @unchecked Sendable {
        let client: NWConnection
        let upstream: NWConnection
        var started = false
        var closed = false
        /// Directions whose source has finished sending.
        var finished = 0

        init(client: NWConnection, upstream: NWConnection) {
            self.client = client
            self.upstream = upstream
        }

        func close() {
            guard !closed else { return }
            closed = true
            client.cancel()
            upstream.cancel()
        }
    }
}
