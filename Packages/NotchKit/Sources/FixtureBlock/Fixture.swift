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
/// - `fetch:<url>`: GET the URL through the kit's `ctx.urlSession` (the
///   app's network gate) and log `fetch ok` when any HTTP response arrives,
///   else `fetch failed`, for the gate tests. The server's certificate is
///   trusted whatever it is: the tests' local server signs its own.
/// - `prefs:<domain>`: read the preferences domain through the preferences
///   service and log `prefs found` when it has any key, else `prefs none`.
/// - `spawn`: start `/bin/sleep 60` as a child process and log
///   `spawned <pid>`, or `spawn failed`, for the process group tests.
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
            } else if command.hasPrefix("fetch:"), let url = URL(string: String(command.dropFirst("fetch:".count))) {
                let task = ctx.urlSession.dataTask(with: url) { _, response, _ in
                    let ok = response is HTTPURLResponse
                    Task { @MainActor in ctx.log(ok ? "fetch ok" : "fetch failed") }
                }
                task.delegate = TrustAnyServer()
                task.resume()
            } else if command.hasPrefix("prefs:") {
                let domain = String(command.dropFirst("prefs:".count))
                let keys = CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
                ctx.log(keys.isEmpty ? "prefs none" : "prefs found")
            } else if command == "spawn" {
                var pid: pid_t = 0
                let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("60"), nil]
                defer { argv.forEach { free($0) } }
                let result = posix_spawn(&pid, "/bin/sleep", nil, nil, argv, nil)
                ctx.log(result == 0 ? "spawned \(pid)" : "spawn failed")
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

/// Accepts any server certificate, for `fetch:` against the tests' local
/// server only. The kit's session itself checks certificates as usual.
private final class TrustAnyServer: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
