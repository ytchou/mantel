import BlockKit
import Foundation

/// A tiny block for BlockHostTests. It says hello and stays alive until the
/// app sends `quit` or closes the socket.
///
/// Test commands arrive through the `command` setting, at `welcome` or as a
/// later `setting` frame:
/// - `crash`: exit at once with status 3, as a crashing block would.
/// - `hang`: block the main thread, so no `pong` goes out.
/// - `ignorePing`: keep running but stop answering pings (the kit answers
///   pings from the main queue, so this is a hang of the main thread too,
///   without the block ever presenting again).
/// - `connect:<port>`: open a TCP connection to 127.0.0.1 on that port and
///   log `connect ok` or `connect failed`, for the sandbox tests.
/// - `write:<path>`: create a file at that path and log `write ok` or
///   `write failed`, for the sandbox tests.
/// - `read:<path>`: open that file for reading and log `read ok` or
///   `read failed`, for the sandbox tests.
/// On a pointer hover it presents a small peek, so tests can see a present.
@main
struct Fixture: Block {
    var id: String { "fixture" }
    var version: String { "1.0.0" }

    func start(_ ctx: Context) {
        if let command = ctx.string("command") { run(command, ctx) }
        ctx.onSettingChanged { key, value in
            if key == "command", let command = value.string { run(command, ctx) }
        }
        ctx.on(.pointerHover) { event in
            guard event.pointerHover?.isInside == true, !event.replay else { return }
            ctx.present(peek: ViewSlot(width: 200, height: 40, root: .text("Fixture", style: .title)), for: 1)
        }
    }

    private func run(_ command: String, _ ctx: Context) {
        switch command {
        case "crash":
            exit(3)
        case "hang", "ignorePing":
            // Holds the main thread. The kit answers pings from it, so the
            // app sees no pong.
            while true { sleep(60) }
        default:
            if command.hasPrefix("connect:"), let port = UInt16(command.dropFirst("connect:".count)) {
                ctx.log(Self.connect(port: port) ? "connect ok" : "connect failed")
            } else if command.hasPrefix("write:") {
                let path = String(command.dropFirst("write:".count))
                // A plain open: Foundation's atomic write goes through a
                // temporary folder the sandbox may refuse.
                let fd = open(path, O_CREAT | O_WRONLY, 0o644)
                if fd >= 0 { close(fd) }
                ctx.log(fd >= 0 ? "write ok" : "write failed")
            } else if command.hasPrefix("read:") {
                let fd = open(String(command.dropFirst("read:".count)), O_RDONLY)
                if fd >= 0 { close(fd) }
                ctx.log(fd >= 0 ? "read ok" : "read failed")
            }
        }
    }

    /// True when a TCP connection to 127.0.0.1:`port` opens.
    private static func connect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
