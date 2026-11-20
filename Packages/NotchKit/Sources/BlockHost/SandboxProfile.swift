import Foundation

/// The sandbox profile a block process runs under, for
/// `/usr/bin/sandbox-exec -p <text>`. A deny list on top of `(allow default)`:
/// no network, no Apple events, no writes outside the block's own folders, no
/// reads inside the home folder. Each access token lifts only its own rule.
///
/// Limit: this stops the plain cases (send a file away, write over a
/// document). It is not a guarantee against a determined attacker; system
/// services stay reachable.
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
    /// The block's `TMPDIR`, writable.
    var temporaryFolder: URL
    /// The owner's home folder.
    var home: URL

    var text: String {
        let home = Self.literal(home)
        let data = Self.literal(dataFolder)
        var lines = ["(version 1)", "(allow default)"]
        if !network { lines.append("(deny network*)") }
        lines.append("(deny appleevent-send)")
        lines.append("(deny file-write*)")
        lines.append("(allow file-write* (subpath \(data)) (subpath \(Self.literal(temporaryFolder))) (subpath \"/dev\"))")
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
        let path = realPath(url) ?? url.standardizedFileURL.path
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
