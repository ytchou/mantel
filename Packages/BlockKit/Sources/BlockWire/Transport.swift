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
    /// not decode; a bad frame is never skipped.
    func envelopes<M: WireMessage>(of type: M.Type) -> AsyncThrowingStream<Envelope<M>, any Error> {
        let frames = self.frames
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await body in frames {
                        continuation.yield(try Framing.decode(body, as: M.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Socket

/// A transport over a connected stream socket, such as one end of a
/// `socketpair`. A block process uses fd 3.
///
/// A dedicated thread does the blocking reads, so a busy main thread never
/// delays a read.
public final class SocketTransport: Transport, @unchecked Sendable {
    // @unchecked: `fd` is immutable; `lock` guards `closed` and is held for
    // every write (so frames never interleave) and for the final close.
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    public let frames: AsyncThrowingStream<Data, any Error>

    /// Takes ownership of `fd` and starts reading at once.
    public init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        frames = stream
        let thread = Thread { [self] in
            readLoop(into: continuation)
            // The fd is closed here, under the lock, so a later `close` or
            // `send` never touches a number the system may have reused.
            lock.withLock {
                closed = true
                Darwin.close(fd)
            }
        }
        thread.name = "BlockWire.SocketTransport"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func send(_ body: Data) throws(FramingError) {
        let frame = try Framing.frame(body)
        let ok = lock.withLock { () -> Bool in
            if closed { return false }
            return frame.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, base + offset, raw.count - offset)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
        }
        if !ok { throw .closed }
    }

    /// Shuts the socket down. The reader thread sees the end, finishes
    /// `frames` and closes the fd.
    public func close() {
        lock.withLock {
            guard !closed else { return }
            shutdown(fd, SHUT_RDWR)
        }
    }

    private func readLoop(into continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
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
            case let .data(body): continuation.yield(body)
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
