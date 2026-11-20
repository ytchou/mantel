import Foundation

/// The sandbox profile a block process runs under, for
/// `/usr/bin/sandbox-exec -p <text>`. A deny list on top of `(allow default)`:
/// no network, no Apple events, no writes outside the block's own folders, no
/// reads inside the home folder, and no reads or writes in the app's
/// `TopNotch` subtree of the temporary folder (dropped files and every
/// block's temporary folder are there) except in the block's own temporary
/// folder inside it. Each access token lifts only its own rule. In SBPL the
/// later rule wins, so each allow follows the deny it narrows.
///
/// Limit: this stops the plain cases (send a file away, write over a
/// document). It is not a guarantee against a determined attacker; system
/// services stay reachable. The rest of the per-user temporary folder stays
/// readable and writable, because Foundation ignores `TMPDIR` and frameworks
/// (FoundationModels, Quick Look thumbnails) write there; so a block can
/// still see other apps' files in it. Closing that needs Foundation to
/// honour `TMPDIR`, or a launcher that sets the per-user folder itself.
struct SandboxProfile: Sendable, Equatable {
    /// `network`: drop the network deny.
    var network: Bool
    /// `files.read`: drop the home read deny.
    var readsHome: Bool
    /// `files.screenshots`: read and write in this folder only.
    var screenshotFolder: URL?
    /// The `.topblock` package, readable.
    var package: URL
    /// The block's data folder, readable and writable.
    var dataFolder: URL
    /// The block's own temporary folder and `TMPDIR`, readable and writable.
    /// `<sharedTemporaryFolder>/TopNotch/Blocks/<block id>/`.
    var temporaryFolder: URL
    /// The app's temporary folder, the per-user one. Writable, like the
    /// data folder; its `TopNotch` subtree (`appTemporaryFolder`) is closed
    /// outside `temporaryFolder`.
    var sharedTemporaryFolder: URL

    /// `<sharedTemporaryFolder>/TopNotch`: the drop folder and every block's
    /// temporary folder. No reads, no writes, except in `temporaryFolder`.
    var appTemporaryFolder: URL { Self.appTemporaryFolder(in: sharedTemporaryFolder) }

    static func appTemporaryFolder(in shared: URL) -> URL {
        shared.appending(path: "TopNotch", directoryHint: .isDirectory)
    }
    /// The owner's home folder.
    var home: URL

    var text: String {
        let home = Self.literal(home)
        let data = Self.literal(dataFolder)
        var lines = ["(version 1)", "(allow default)"]
        if !network { lines.append("(deny network*)") }
        lines.append("(deny appleevent-send)")
        lines.append("(deny file-write*)")
        lines.append("(allow file-write* (subpath \(data)) (subpath \(Self.literal(sharedTemporaryFolder))) (subpath \"/dev\"))")
        // After the write allow above, which covers the shared folder.
        lines.append("(deny file-read* file-write* (subpath \(Self.literal(appTemporaryFolder))))")
        lines.append("(allow file-read* file-write* (subpath \(Self.literal(temporaryFolder))))")
        if !readsHome { lines.append("(deny file-read* (subpath \(home)))") }
        lines.append("(allow file-read* (subpath \(data)) (subpath \(Self.literal(package))))")
        if let screenshotFolder {
            lines.append("(allow file-read* file-write* (subpath \(Self.literal(screenshotFolder))))")
        }
        // Always present, whatever the tokens: without metadata reads in the
        // home folder the on-device model (FoundationModels) reports
        // "Apple Intelligence not enabled". Probed on macOS 26, 2026-11-20.
        lines.append("(allow file-read-metadata (subpath \(home)))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A quoted SBPL string for `url`'s path, with symbolic links resolved
    /// (the sandbox matches the real path: `/var/...` is `/private/var/...`)
    /// and `"` and `\` escaped.
    // Resolves only a path that exists; build the profile after creating the
    // block's folders. A missing path is used as given.
    static func literal(_ url: URL) -> String {
        let path = resolvedPath(url)
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// `url`'s path with symbolic links resolved when it exists, else as given.
    static func resolvedPath(_ url: URL) -> String {
        realPath(url) ?? url.standardizedFileURL.path
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
