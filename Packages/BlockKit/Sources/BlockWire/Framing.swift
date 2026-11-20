import Foundation

// A frame is a 4-byte little-endian body length, then the body: one
// `Envelope` encoded as JSON with sorted keys. Bodies over
// `Contract.maxFrameBytes` are refused on both sides.

public enum FramingError: Error, Equatable, Sendable {
    /// The body is over the limit. Raised from the length alone, before the
    /// body is read.
    case tooLarge(length: Int, limit: Int)
    /// The bytes end before the frame does.
    case truncated(expected: Int, got: Int)
    /// The body is not a valid envelope. The value describes why.
    case malformed(String)
    /// The other side is gone; nothing more can be sent.
    case closed
}

public enum Framing {
    public static let headerSize = 4

    /// The 4-byte header for a body of `length` bytes.
    public static func header(forBodyLength length: Int) throws(FramingError) -> Data {
        try checkLength(length)
        var value = UInt32(length).littleEndian
        return Data(bytes: &value, count: headerSize)
    }

    /// Reads the body length from a header. Throws before any body is read
    /// when the length is over the limit.
    public static func bodyLength(fromHeader header: Data) throws(FramingError) -> Int {
        guard header.count >= headerSize else {
            throw .truncated(expected: headerSize, got: header.count)
        }
        let length = header.prefix(headerSize).withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        try checkLength(length)
        return length
    }

    /// Header plus body.
    public static func frame(_ body: Data) throws(FramingError) -> Data {
        var data = try header(forBodyLength: body.count)
        data.append(body)
        return data
    }

    /// The body of one complete frame.
    public static func unframe(_ frame: Data) throws(FramingError) -> Data {
        let length = try bodyLength(fromHeader: frame)
        let available = frame.count - headerSize
        guard available >= length else {
            throw .truncated(expected: length, got: available)
        }
        return frame.dropFirst(headerSize).prefix(length)
    }

    /// Encodes one message in an envelope, as a frame body.
    public static func encode<M: WireMessage>(_ message: M, generation: Int) throws(FramingError) -> Data {
        let body: Data
        do {
            body = try encoder().encode(Envelope(generation: generation, message: message))
        } catch {
            throw .malformed("cannot encode: \(error)")
        }
        try checkLength(body.count)
        return body
    }

    /// Decodes one frame body. A body that does not decode is an error.
    public static func decode<M: WireMessage>(_ body: Data, as type: M.Type = M.self) throws(FramingError) -> Envelope<M> {
        do {
            return try JSONDecoder().decode(Envelope<M>.self, from: body)
        } catch {
            throw .malformed(String(describing: error))
        }
    }

    /// The encoder used for every frame: sorted keys, so the same message
    /// always gives the same bytes.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func checkLength(_ length: Int) throws(FramingError) {
        if length > Contract.maxFrameBytes {
            throw .tooLarge(length: length, limit: Contract.maxFrameBytes)
        }
    }
}

