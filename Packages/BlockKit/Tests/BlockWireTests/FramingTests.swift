import Foundation
import Testing
@testable import BlockWire

struct FramingTests {
    @Test func frameRejectsOversized() async throws {
        let tooBig = Contract.maxFrameBytes + 1
        var length = UInt32(tooBig).littleEndian
        let header = Data(bytes: &length, count: 4)

        // From the header alone, with no body present.
        #expect(throws: FramingError.tooLarge(length: tooBig, limit: Contract.maxFrameBytes)) {
            try Framing.bodyLength(fromHeader: header)
        }
        #expect(throws: FramingError.tooLarge(length: tooBig, limit: Contract.maxFrameBytes)) {
            try Framing.unframe(header)
        }
        // Nor can one be sent.
        #expect(throws: FramingError.tooLarge(length: tooBig, limit: Contract.maxFrameBytes)) {
            try Framing.frame(Data(count: tooBig))
        }

        // Over a socket: the reader fails on the header and never waits for
        // the 4 MB body that was never written.
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let reader = SocketTransport(fd: fds[0])
        header.withUnsafeBytes { _ = write(fds[1], $0.baseAddress, 4) }
        await #expect(throws: FramingError.tooLarge(length: tooBig, limit: Contract.maxFrameBytes)) {
            for try await _ in reader.frames {}
        }
        close(fds[1])
    }

    @Test func frameRejectsShortAndGarbage() async throws {
        let body = try Framing.encode(BlockToHost.pong(seq: 1), generation: 1)
        let frame = try Framing.frame(body)

        // Truncated: the frame ends early.
        #expect(throws: FramingError.truncated(expected: body.count, got: body.count - 3)) {
            try Framing.unframe(frame.dropLast(3))
        }
        #expect(throws: FramingError.truncated(expected: 4, got: 2)) {
            try Framing.bodyLength(fromHeader: Data([1, 0]))
        }

        // Garbage: a full frame whose body is not an envelope.
        let garbage = Data("not json".utf8)
        #expect(throws: FramingError.self) {
            try Framing.decode(try Framing.unframe(Framing.frame(garbage)), as: BlockToHost.self)
        }
        do {
            _ = try Framing.decode(garbage, as: BlockToHost.self)
            Issue.record("garbage decoded")
        } catch {
            guard case .malformed = error else { Issue.record("expected malformed, got \(error)"); return }
        }

        // Over a socket: a frame cut off by the peer closing is an error.
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let reader = SocketTransport(fd: fds[0])
        let cut = frame.dropLast(3)
        cut.withUnsafeBytes { _ = write(fds[1], $0.baseAddress, cut.count) }
        close(fds[1])
        await #expect(throws: FramingError.truncated(expected: body.count, got: body.count - 3)) {
            for try await _ in reader.frames {}
        }

        // Over a transport: a body that does not decode ends the stream with
        // an error; it is not skipped.
        let (a, b) = MemoryTransport.pair()
        b.injectReceived(garbage)
        try a.send(BlockToHost.pong(seq: 2), generation: 1)
        var seen: [Envelope<BlockToHost>] = []
        do {
            for try await envelope in b.envelopes(of: BlockToHost.self) { seen.append(envelope) }
            Issue.record("stream ended without error")
        } catch {
            guard case FramingError.malformed = error else { Issue.record("expected malformed, got \(error)"); return }
        }
        #expect(seen.isEmpty)
    }

    @Test func socketTransportCarriesFramesBothWays() async throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let host = SocketTransport(fd: fds[0])
        let block = SocketTransport(fd: fds[1])

        try block.send(BlockToHost.hello(contract: 1, id: "a", version: "1"), generation: 4)
        var hostIterator = host.envelopes(of: BlockToHost.self).makeAsyncIterator()
        #expect(try await hostIterator.next() == Envelope(generation: 4, message: .hello(contract: 1, id: "a", version: "1")))

        try host.send(HostToBlock.quit, generation: 4)
        var blockIterator = block.envelopes(of: HostToBlock.self).makeAsyncIterator()
        #expect(try await blockIterator.next() == Envelope(generation: 4, message: .quit))

        host.close()
        #expect(try await blockIterator.next() == nil)
        #expect(throws: FramingError.closed) { try host.send(HostToBlock.quit, generation: 4) }
    }
}
