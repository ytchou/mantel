import Foundation

/// The sandbox profile a block process runs under, for
/// `/usr/bin/sandbox-exec -p <text>`. On top of `(allow default)`: no network
/// except the block's own network gate, no name lookups, no Apple events, no
/// preference writes and no reads of Mantel's preferences domain, no writes
/// outside the block's own folders, and reads only from an allow-list: the
/// system locations a process needs, the block's package, data folder and
/// own temporary folder, and what its tokens open. The app's `Mantel`
/// subtree of the temporary folder (dropped files and every block's
/// temporary folder) is closed except the block's own folder inside it.
/// `files.read` opens the home folder and other volumes (`/Volumes`), but
/// never Mantel's support folder (other blocks' packages and data, the
/// approvals) or the app's preferences file, whatever a token opens: those
/// are closed after every token's allow. In SBPL the last matching rule
/// wins, so each allow follows the deny it narrows; but a rule for one
/// operation (`file-read-metadata`) beats a wildcard (`file-read*`) in any
/// order. `allowsRead(_:)` answers the same question in the app. The rules were measured on macOS 26.5 (`spikes/FINDINGS.md`,
/// "Sandbox rules, 21 Nov").
///
/// Limits that remain:
/// - It stops the plain cases (send a file away, read another block's data,
///   write over a document). It is not a guarantee against a determined
///   attacker; system services stay reachable.
/// - Writes into the per-user temporary folder stay open, because Foundation
///   ignores `TMPDIR` and frameworks (FoundationModels, Quick Look
///   thumbnails) write there. Reads there are closed outside the block's own
///   folder, so two blocks cannot pass files through it by reading. Metadata
///   there stays readable outside the app's `Mantel` subtree (whether a
///   named file exists, its size and dates, not listings): Foundation needs
///   it to create folders and open files for writing.
/// - Metadata of anything in the home folder stays readable (names, sizes,
///   dates): without it the on-device model reports "Apple Intelligence not
///   enabled".
/// - Other apps' preference domains stay readable through the preferences
///   service: denying every preference read breaks the on-device model.
///   Nothing a block must not see is kept in Mantel's own domain, which
///   is closed.
/// - Quick Look thumbnails ignore the read allow-list: the thumbnail service
///   reads the file, not the block, so a block can get a picture of any file
///   it can name and learn whether it exists. Its Mach services stay open
///   because blocks make thumbnails with `QLThumbnailGenerator`.
///   Closing it needs thumbnails drawn by the app instead of the block.
/// - `files.read` opens every mounted volume under `/Volumes` whole, not
///   only the home folder: files on external disks must stay readable.
/// - System services can fetch from the network for a block, outside the
///   network gate: `(deny network*)` covers the block's own process only.
///   A background `URLSession` (run by `nsurlsessiond`) or LaunchServices
///   opening a URL in another app reaches any host. Closing them needs
///   their Mach services denied, which may break frameworks blocks use;
///   that needs a follow-up spike.
/// - A block's child processes inherit its sandbox and are ended with it
///   (`BlockProcess` signals its process group), but a child that leaves
///   the group (`setsid`, `setpgid`) is not ended, and the resource watch
///   counts the block's own process only, not its children.
struct SandboxProfile: Sendable, Equatable {
    /// The local port of the block's network gate, the only network the
    /// block reaches. Nil without hosts: no network at all.
    var gatePort: UInt16?
    /// `files.read`: allow reads in the home folder and under `/Volumes`,
    /// except Mantel's folders.
    var readsHome: Bool
    /// `files.screenshots`: read and write in this folder, except Mantel's
    /// folders and the preferences file inside it.
    var screenshotFolder: URL?
    /// The `.mantelblock` package, readable.
    var package: URL
    /// The block's data folder, readable and writable.
    var dataFolder: URL
    /// The block's own temporary folder and `TMPDIR`, readable and writable.
    /// `<sharedTemporaryFolder>/Mantel/Blocks/<block id>/`.
    var temporaryFolder: URL
    /// The app's temporary folder, the per-user one. Writable, like the
    /// data folder, not readable; its `Mantel` subtree
    /// (`appTemporaryFolder`) is closed outside `temporaryFolder`.
    var sharedTemporaryFolder: URL
    /// The owner's home folder.
    var home: URL
    /// Mantel's support folder, `~/Library/Application Support/Mantel`:
    /// installed packages, every block's data, the approvals. Closed even
    /// with `files.read`, except the block's own package and data folder.
    var supportRoot: URL
    /// The app's preferences file, closed even with `files.read`.
    var preferencesFile: URL
    /// The app's preferences domain, closed to reads through the preferences
    /// service.
    var preferenceDomain: String

    /// `<sharedTemporaryFolder>/Mantel`: the drop folder and every block's
    /// temporary folder. No reads, no writes, except in `temporaryFolder`.
    var appTemporaryFolder: URL { Self.appTemporaryFolder(in: sharedTemporaryFolder) }

    static func appTemporaryFolder(in shared: URL) -> URL {
        shared.appending(path: "Mantel", directoryHint: .isDirectory)
    }

    /// What a process needs to read outside the home folder to start and to
    /// use the system frameworks blocks use (FoundationModels, Quick Look).
    /// Measured: without
    /// `/private/var/db/eligibilityd` the model reports `deviceNotEligible`;
    /// without the root links `/etc`, `/var` and `/tmp` name lookups fail.
    /// `literal` is the path itself only; otherwise everything below it too.
    static let systemReadPaths: [(path: String, literal: Bool)] = [
        ("/", true), ("/etc", true), ("/var", true), ("/tmp", true),
        ("/System", false), ("/usr", false), ("/bin", false), ("/sbin", false),
        ("/Library/Apple", false), ("/Library/Preferences", false), ("/private/etc", false),
        ("/private/var/db/timezone", false), ("/private/var/db/dyld", false),
        ("/private/var/db/eligibilityd", false), ("/dev", false),
    ]

    /// `systemReadPaths` as SBPL filters.
    static var systemReadLocations: [String] {
        systemReadPaths.map { "(\($0.literal ? "literal" : "subpath") \(quoted($0.path)))" }
    }

    var text: String {
        let home = Self.literal(home)
        let data = Self.literal(dataFolder)
        let package = Self.literal(package)
        let temporary = Self.literal(temporaryFolder)
        var lines = ["(version 1)", "(allow default)"]
        // The `network` token no longer lifts this: a block reaches only its
        // gate, which lets through the hosts its manifest names.
        lines.append("(deny network*)")
        if let gatePort {
            lines.append("(allow network-outbound (remote tcp \"localhost:\(gatePort)\"))")
        }
        // URLSession resolves names through this service even with the
        // network denied; the gate resolves for the block.
        lines.append(#"(deny mach-lookup (global-name "com.apple.dnssd.service"))"#)
        lines.append("(deny appleevent-send)")
        // Not the cfprefsd Mach services: denying them breaks FoundationModels.
        lines.append("(deny user-preference-write)")
        lines.append("(deny user-preference-read (preference-domain \(Self.quoted(preferenceDomain))))")
        lines.append("(deny file-write*)")
        lines.append("(allow file-write* (subpath \(data)) (subpath \(Self.literal(sharedTemporaryFolder))) (subpath \"/dev\"))")
        // Reads: an allow-list from here on.
        lines.append("(deny file-read*)")
        lines.append("(allow file-read* " + Self.systemReadLocations.joined(separator: " ") + ")")
        // Metadata in the shared temporary folder, never its contents or
        // listings: without it Foundation cannot write there
        // (`createDirectory(withIntermediateDirectories:)`, `FileHandle`)
        // and `touch` fails. A rule for `file-read-metadata` beats any
        // `file-read*` rule whatever their order, so the app's subtree is
        // closed again and the block's own folder reopened with the same
        // operation. Probed on macOS 26, 2026-11-21.
        lines.append("(allow file-read-metadata (subpath \(Self.literal(sharedTemporaryFolder))))")
        lines.append("(deny file-read-metadata (subpath \(Self.literal(appTemporaryFolder))))")
        lines.append("(allow file-read-metadata (subpath \(temporary)))")
        if readsHome {
            // Other volumes too: files on external disks stay readable, as
            // before the allow-list. The closing deny below still wins there.
            lines.append("(allow file-read* (subpath \(home)) (subpath \"/Volumes\"))")
        }
        if let screenshotFolder {
            lines.append("(allow file-read* file-write* (subpath \(Self.literal(screenshotFolder))))")
        }
        // After every allow a token adds, so no token reopens them (a
        // screenshot folder set to the home folder contains all three):
        // the app's temporary subtree, Mantel's support folder and the
        // preferences file. Then the block's own folders, inside them in
        // the app, are opened again.
        lines.append("(deny file-read* file-write* (subpath \(Self.literal(appTemporaryFolder))) "
            + "(subpath \(Self.literal(supportRoot))) (literal \(Self.literal(preferencesFile))))")
        lines.append("(allow file-read* file-write* (subpath \(data)) (subpath \(temporary)))")
        lines.append("(allow file-read* (subpath \(package)))")
        // Always present, whatever the tokens: without metadata reads in the
        // home folder the on-device model (FoundationModels) reports
        // "Apple Intelligence not enabled". Probed on macOS 26, 2026-11-20.
        lines.append("(allow file-read-metadata (subpath \(home)))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// True when this profile lets the block read the file at `path`, an
    /// absolute path, with symbolic links followed: the same rule as `text`.
    /// The app uses it before it shows or drags out a file the block names,
    /// and before it hands a dropped file over where it is, so it never
    /// opens for the block what the sandbox closes. Metadata-only rules
    /// (the shared temporary folder, the home folder) do not count.
    func allowsRead(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let target = Self.resolvedPath(URL(fileURLWithPath: path))
        func inside(_ url: URL) -> Bool { Self.isInside(target, Self.resolvedPath(url)) }
        // In `text`'s order, last rule first.
        if [dataFolder, temporaryFolder, package].contains(where: inside) { return true }
        if [appTemporaryFolder, supportRoot, preferencesFile].contains(where: inside) { return false }
        if let screenshotFolder, inside(screenshotFolder) { return true }
        if readsHome, inside(home) || Self.isInside(target, "/Volumes") { return true }
        return Self.systemReadPaths.contains { $0.literal ? target == $0.path : Self.isInside(target, $0.path) }
    }

    /// True when `path` is `root` or inside it.
    static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// A quoted SBPL string for `url`'s path, with symbolic links resolved
    /// (the sandbox matches the real path: `/var/...` is `/private/var/...`)
    /// and `"` and `\` escaped.
    // Resolves only a path that exists; build the profile after creating the
    // block's folders. A missing path is used as given.
    static func literal(_ url: URL) -> String {
        quoted(resolvedPath(url))
    }

    /// `text` as a quoted SBPL string, `"` and `\` escaped.
    static func quoted(_ text: String) -> String {
        let escaped = text
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
