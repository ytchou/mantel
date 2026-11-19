import Foundation
import QuartzCore

// Transport: one AF_UNIX stream socket from socketpair(2). The host keeps one
// end and passes the other to the block as fd 3 at posix_spawn time.
// Framing: 4-byte little-endian length, then a JSON-encoded `Msg`.

public struct Rect: Codable, Sendable {
    public var x, y, w, h: Double
    public init(_ r: CGRect) { x = r.minX; y = r.minY; w = r.width; h = r.height }
    public var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

public enum Input: Codable, Sendable {
    case hover(Bool)
    case click
    case dragOver(String)
    case drop([String])
}

/// One message in either direction.
public enum Msg: Codable, Sendable {
    // block -> host
    case hello(stage: String, t: Double, pid: Int32)
    case pong(seq: Int)
    /// Option 1: the block's view as data.
    case describe(seq: Int, nodes: [Node], t0: Double)
    /// Options 2 and 3: the block committed the frame that shows input `seq`.
    case committed(seq: Int, t0: Double, tRecv: Double, tBody: Double, tCommit: Double, tFrame: Double)
    case layerContext(id: UInt32, route: String)
    case window(number: Int)
    case log(String)

    // host -> block
    case ping(seq: Int, onMain: Bool)
    case setup(option: String, frame: Rect, level: Int, route: String, manual: Bool)
    case input(seq: Int, input: Input, t0: Double)
    /// Option 2: the block injects a click into its own window (it owns the input surface).
    case injectClick(seq: Int)
    /// Option 2: the block calls its own drag-over handler (it owns the drop target).
    case injectDragOver(seq: Int, name: String)
    /// Options 2/3: content area moved or resized.
    case setFrame(seq: Int, frame: Rect, t0: Double)
    case crash
    case hang(seconds: Double)
    /// Stop the display link before an idle resource sample.
    case idle
    case quit
}

public final class Channel: @unchecked Sendable {
    public let fd: Int32
    private let writeLock = NSLock()
    /// Called on the reader thread.
    public var onMessage: ((Msg) -> Void)?
    /// Called on the reader thread with CACurrentMediaTime() when the peer closed.
    public var onClose: ((Double) -> Void)?

    public init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    public func start() {
        let t = Thread { [self] in readLoop() }
        t.name = "channel-reader"
        t.qualityOfService = .userInteractive
        t.start()
    }

    @discardableResult
    public func send(_ msg: Msg) -> Bool {
        guard let body = try? JSONEncoder().encode(msg) else { return false }
        var len = UInt32(body.count).littleEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        writeLock.lock(); defer { writeLock.unlock() }
        return frame.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    private func readExact(_ count: Int) -> Data? {
        var data = Data(count: count)
        var off = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            while off < count {
                let n = read(fd, raw.baseAddress! + off, count - off)
                if n == 0 { return false }
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        return ok ? data : nil
    }

    private func readLoop() {
        let decoder = JSONDecoder()
        while true {
            guard let head = readExact(4) else { break }
            let len = head.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard let body = readExact(len) else { break }
            if let msg = try? decoder.decode(Msg.self, from: body) { onMessage?(msg) }
        }
        onClose?(CACurrentMediaTime())
    }

    public func close() { Darwin.close(fd) }
}

public func now() -> Double { CACurrentMediaTime() }

public struct Stats {
    public let n: Int, median: Double, p95: Double, mean: Double, min: Double, max: Double
    /// `values` in seconds; fields in milliseconds.
    public init(_ values: [Double]) {
        let v = values.filter { $0.isFinite }.sorted().map { $0 * 1000 }
        n = v.count
        func pct(_ p: Double) -> Double { v.isEmpty ? .nan : v[Swift.min(v.count - 1, Int((Double(v.count - 1) * p).rounded()))] }
        median = pct(0.5); p95 = pct(0.95)
        mean = v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
        min = v.first ?? .nan; max = v.last ?? .nan
    }
    public var line: String {
        String(format: "n=%d median=%.3f p95=%.3f mean=%.3f min=%.3f max=%.3f ms", n, median, p95, mean, min, max)
    }
}

public func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}
