import Foundation

/// Where the shell writes files it receives as promises in a drop (a
/// dragged image without a file, for example), one `<uuid>` folder per drop.
/// One place, so the shell and the block host agree: a block's stand-in moves
/// each dropped file inside it into that block's own temporary folder.
public enum DropFolder {
    /// `<app temporary folder>/TopNotch/Drops/`. Emptied when the shell starts.
    public static var root: URL {
        FileManager.default.temporaryDirectory.appending(path: "TopNotch/Drops", directoryHint: .isDirectory)
    }
}
