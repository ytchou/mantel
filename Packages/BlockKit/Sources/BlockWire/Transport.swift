import Foundation

/// Moves frame bodies between the app and one block.
///
/// `frames` has one consumer. It ends normally when the other side closes,
/// and throws a `FramingError` on a bad frame.
public protocol Transport: AnyObject, Sendable {
    /// Sends one frame body. Throws `FramingError.closed` once the transport
    /// is closed, and `tooLarge` for a body over the limit.
    func send(_ body: Data) throws(FramingError)
    /// Bodies received, in order.
    var frames: AsyncThrowingStream<Data, any Error> { get }
    /// Closes both directions. `frames` ends on both sides.
    func close()
}

public extension Transport {
    /// Encodes one message in an envelope and sends it.
    func send<M: WireMessage>(_ message: M, generation: Int) throws(FramingError) {
        try send(Framing.encode(message, generation: generation))
    }

    /// Received frames decoded as `M`. Throws on the first frame that does
    /// not decode; a bad frame is never skipped. Frames are read and decoded
    /// only as the consumer asks for them, so this adds no buffer of its own.
    func envelopes<M: WireMessage>(of type: M.Type) -> AsyncThrowingStream<Envelope<M>, any Error> {
        let frames = IteratorBox(frames.makeAsyncIterator())
        return AsyncThrowingStream {
            guard let body = try await frames.next() else { return nil }
            return try Framing.decode(body, as: M.self)
        }
    }
}

/// Why a transport ended, other than a bad frame.
public enum TransportError: Error, Equatable, Sendable {
    /// More than `limit` bytes of frames were waiting to be read: the other
    /// side sends faster than this side reads.
    case overflow(limit: Int)
}

/// Holds the iterator of a stream read on demand. One consumer, as `frames` has.
final class IteratorBox<Base: AsyncIteratorProtocol>: @unchecked Sendable {
    // @unchecked: only the single consumer calls `next`, one call at a time.
    private var base: Base

    init(_ base: Base) { self.base = base }

    func next() async throws -> Base.Element? { try await base.next() }
}

// MARK: - Socket

/// A transport over a connected stream socket, such as one end of a
/// `socketpair`. A block process uses fd 3.
///
/// A dedicated thread does the blocking reads, so a busy main thread never
/// delays a read. Frames read and not yet consumed are limited to
/// `maxQueuedBytes`; past that the stream ends with `TransportError.overflow`.
public final class SocketTransport: Transport, @unchecked Sendable {
    // @unchecked: `fd` is immutable. `state` guards `closed`; it is never
    // held across a write, so `close` can shut the socket down while a write
    // is stuck. `writing` is held for every write (so frames never
    // interleave) and while the reader thread closes the fd.
    private let fd: Int32
    private let state = NSLock()
    private let writing = NSLock()
    private var closed = false
    public let frames: AsyncThrowingStream<Data, any Error>

    /// The default limit on frames read and not yet consumed.
    public static let defaultMaxQueuedBytes = 4 * Contract.maxFrameBytes
    /// Counted for each frame on top of its body, so many tiny frames also fill the limit.
    static let frameCost = 64

    /// Takes ownership of `fd` and starts reading at once.
    /// - Parameters:
    ///   - sendTimeout: how long one write may wait for the other side to
    ///     read. A send that times out shuts the socket down and throws
    ///     `FramingError.closed`. Nil waits as long as it takes.
    ///   - maxQueuedBytes: frames read and not yet consumed, at most.
    public init(fd: Int32, sendTimeout: Duration? = nil, maxQueuedBytes: Int = SocketTransport.defaultMaxQueuedBytes) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if let sendTimeout {
            let (seconds, attoseconds) = sendTimeout.components
            var limit = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        }
        let backlog = Backlog()
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let queued = IteratorBox(stream.makeAsyncIterator())
        frames = AsyncThrowingStream {
            guard let body = try await queued.next() else { return nil }
            backlog.remove(body.count + Self.frameCost)
            return body
        }
        let thread = Thread { [self] in
            readLoop(into: continuation, backlog: backlog, limit: maxQueuedBytes)
            // Wake a write that may be stuck, so the fd can be closed.
            state.withLock { if !closed { shutdown(fd, SHUT_RDWR) } }
            // The fd is closed here, with no write in progress, so a later
            // `close` or `send` never touches a number the system may have reused.
            writing.withLock {
                state.withLock {
                    closed = true
                    Darwin.close(fd)
                }
            }
        }
        thread.name = "BlockWire.SocketTransport"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func send(_ body: Data) throws(FramingError) {
        let frame = try Framing.frame(body)
        let ok = writing.withLock { () -> Bool in
            if state.withLock({ closed }) { return false }
            let ok = frame.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, base + offset, raw.count - offset)
                    if n < 0, errno == EINTR { continue }
                    // n < 0 with EAGAIN is the send timeout.
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            // A frame may be half written: nothing more can follow it.
            if !ok { close() }
            return ok
        }
        if !ok { throw .closed }
    }

    /// Shuts the socket down, even while a write is stuck. The reader thread
    /// sees the end, finishes `frames` and closes the fd.
    public func close() {
        state.withLock {
            guard !closed else { return }
            shutdown(fd, SHUT_RDWR)
        }
    }

    /// Bytes of frames read and not yet consumed.
    private final class Backlog: @unchecked Sendable {
        // @unchecked: `lock` guards `bytes`.
        private let lock = NSLock()
        private var bytes = 0

        /// Adds `count` and returns the new total.
        func add(_ count: Int) -> Int { lock.withLock { bytes += count; return bytes } }
        func remove(_ count: Int) { lock.withLock { bytes -= count } }
    }

    private func readLoop(
        into continuation: AsyncThrowingStream<Data, any Error>.Continuation, backlog: Backlog, limit: Int
    ) {
        while true {
            let header: Data
            switch readExact(Framing.headerSize) {
            case let .data(data): header = data
            case .end(got: 0): continuation.finish(); return
            case let .end(got):
                continuation.finish(throwing: FramingError.truncated(expected: Framing.headerSize, got: got))
                return
            }
            let length: Int
            do {
                // Checks the limit before the body is allocated.
                length = try Framing.bodyLength(fromHeader: header)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            switch readExact(length) {
            case let .data(body):
                if backlog.add(body.count + Self.frameCost) > limit {
                    continuation.finish(throwing: TransportError.overflow(limit: limit))
                    return
                }
                continuation.yield(body)
            case let .end(got):
                continuation.finish(throwing: FramingError.truncated(expected: length, got: got))
                return
            }
        }
    }

    private enum ReadResult {
        case data(Data)
        /// The stream ended after `got` bytes of this read.
        case end(got: Int)
    }

    private func readExact(_ count: Int) -> ReadResult {
        guard count > 0 else { return .data(Data()) }
        var data = Data(count: count)
        var offset = 0
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < count {
                let n = read(fd, base + offset, count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return complete ? .data(data) : .end(got: offset)
    }
}

// MARK: - Memory

/// Two transports joined in memory, for tests.
public final class MemoryTransport: Transport, @unchecked Sendable {
    // @unchecked: the continuations are thread-safe; `link` guards the shared
    // closed flag.
    private final class Link: @unchecked Sendable {
        let lock = NSLock()
        var closed = false
        var ends: [AsyncThrowingStream<Data, any Error>.Continuation] = []
    }

    private let link: Link
    private let inbox: AsyncThrowingStream<Data, any Error>.Continuation
    private let outbox: AsyncThrowingStream<Data, any Error>.Continuation
    public let frames: AsyncThrowingStream<Data, any Error>

    private init(
        frames: AsyncThrowingStream<Data, any Error>,
        inbox: AsyncThrowingStream<Data, any Error>.Continuation,
        outbox: AsyncThrowingStream<Data, any Error>.Continuation,
        link: Link
    ) {
        self.frames = frames
        self.inbox = inbox
        self.outbox = outbox
        self.link = link
    }

    /// Two connected ends: what one sends, the other receives.
    public static func pair() -> (MemoryTransport, MemoryTransport) {
        let (a, toA) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (b, toB) = AsyncThrowingStream<Data, any Error>.makeStream()
        let link = Link()
        link.ends = [toA, toB]
        return (
            MemoryTransport(frames: a, inbox: toA, outbox: toB, link: link),
            MemoryTransport(frames: b, inbox: toB, outbox: toA, link: link)
        )
    }

    public func send(_ body: Data) throws(FramingError) {
        _ = try Framing.header(forBodyLength: body.count)
        let closed = link.lock.withLock { link.closed }
        if closed { throw .closed }
        outbox.yield(body)
    }

    public func close() {
        let ends = link.lock.withLock { () -> [AsyncThrowingStream<Data, any Error>.Continuation] in
            if link.closed { return [] }
            link.closed = true
            return link.ends
        }
        ends.forEach { $0.finish() }
    }

    /// Delivers bytes to this end as if the other side had sent them. For
    /// tests of bad input.
    public func injectReceived(_ body: Data) {
        inbox.yield(body)
    }
}
