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
/// On a pointer hover it presents a small peek, so tests can see a present.
@main
struct Fixture: Block {
    var id: String { "fixture" }
    var version: String { "1.0.0" }

    func start(_ ctx: Context) {
        if let command = ctx.string("command") { run(command) }
        ctx.onSettingChanged { key, value in
            if key == "command", let command = value.string { run(command) }
        }
        ctx.on(.pointerHover) { event in
            guard event.pointerHover?.isInside == true, !event.replay else { return }
            ctx.present(peek: ViewSlot(width: 200, height: 40, root: .text("Fixture", style: .title)), for: 1)
        }
    }

    private func run(_ command: String) {
        switch command {
        case "crash":
            exit(3)
        case "hang", "ignorePing":
            // Holds the main thread. The kit answers pings from it, so the
            // app sees no pong.
            while true { sleep(60) }
        default:
            break
        }
    }
}
