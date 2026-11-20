import Darwin
import Foundation
import Testing
@testable import BlockWire

/// `SocketTransport` limits: a stuck peer never blocks a send for good, and a
/// flooding peer never grows the reader's buffer without bound.
@Suite(.serialized)
struct TransportTests {
    @Test func sendTimesOutWhenThePeerStopsReading() async throws {
        let (fd, peer) = try socketPair()
        defer { Darwin.close(peer) }
        let host = SocketTransport(fd: fd, sendTimeout: .milliseconds(100))

        // The peer never reads: the socket buffer fills, then a send times out.
        let outcome = await offThread(within: .seconds(5)) { () -> Bool in
            let body = Data(count: 1024 * 1024)
            for _ in 0..<64 {
                do { try host.send(body) } catch { return (error as? FramingError) == .closed }
            }
            return false
        }
        #expect(outcome == true, "a send to a peer that stopped reading fails within its timeout")
        // A timed-out send leaves a partial frame: the transport is shut down.
        #expect(throws: FramingError.closed) { try host.send(Data([1])) }
    }

    @Test func closeEndsAStuckSend() async throws {
        let (fd, peer) = try socketPair()
        defer { Darwin.close(peer) }
        // No timeout, as on the block's side.
        let host = SocketTransport(fd: fd)

        // The peer never reads: the first 4 MB frame fills the buffer and the write waits.
        let sent = Box<FramingError>()
        Thread {
            let body = Data(count: Contract.maxFrameBytes)
            for _ in 0..<8 {
                do { try host.send(body) } catch { sent.set(error as? FramingError ?? .closed); return }
            }
        }.start()
        try await Task.sleep(for: .milliseconds(200))

        let closed = await offThread(within: .seconds(2)) { host.close(); return true }
        #expect(closed == true, "close does not wait for the stuck write")
        #expect(await sent.wait(within: .seconds(2)) == .closed, "the stuck send ends with closed")
    }

    @Test func aFloodingPeerEndsTheStream() async throws {
        let (fd, peerFD) = try socketPair()
        let host = SocketTransport(fd: fd, maxQueuedBytes: 2_000)
        let peer = SocketTransport(fd: peerFD)
        defer { peer.close() }

        // Nobody reads `host.frames` while the peer sends.
        // The host may close on overflow before the loop ends; a send failing then is expected.
        for _ in 0..<50 {
            do { try peer.send(Data(count: 100)) } catch { break }
        }
        try await Task.sleep(for: .milliseconds(200))

        var count = 0
        do {
            for try await _ in host.frames { count += 1 }
            Issue.record("stream ended without error after \(count) frames")
        } catch {
            #expect(error as? TransportError == .overflow(limit: 2_000))
        }
        #expect(count < 50)
    }

    @Test func framesAreReadOnDemandAfterTheBacklogDrains() async throws {
        let (fd, peerFD) = try socketPair()
        let host = SocketTransport(fd: fd, maxQueuedBytes: 2_000)
        let peer = SocketTransport(fd: peerFD)

        // Read as they come: the backlog never fills.
        var iterator = host.frames.makeAsyncIterator()
        for n in 0..<50 {
            try peer.send(Data(repeating: UInt8(n), count: 100))
            #expect(try await iterator.next() == Data(repeating: UInt8(n), count: 100))
        }
        peer.close()
        #expect(try await iterator.next() == nil)
    }

    // MARK: Helpers

    private func socketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return (fds[0], fds[1])
    }

    /// Runs `work` on its own thread and returns its result, or nil when it
    /// has not finished within `limit`. A stuck `work` fails the test
    /// instead of hanging it.
    private func offThread<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () -> T) async -> T? {
        let result = Box<T>()
        Thread { result.set(work()) }.start()
        return await result.wait(within: limit)
    }
}

/// One value set from another thread.
private final class Box<T: Sendable>: @unchecked Sendable {
    // @unchecked: `lock` guards `value`.
    private let lock = NSLock()
    private var value: T?

    func set(_ value: T) { lock.withLock { self.value = value } }

    /// The value, once set within `limit`; nil otherwise.
    func wait(within limit: Duration) async -> T? {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if let value = lock.withLock({ value }) { return value }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return lock.withLock { value }
    }
}
