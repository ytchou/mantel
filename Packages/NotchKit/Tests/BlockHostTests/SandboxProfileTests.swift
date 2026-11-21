import Foundation
import Testing
@testable import BlockHost

@Suite
struct SandboxProfileTests {
    /// Paths that do not exist, so the builder keeps them as given.
    private func profile(gatePort: UInt16? = nil, readsHome: Bool = false, screenshotFolder: URL? = nil) -> SandboxProfile {
        SandboxProfile(
            gatePort: gatePort,
            readsHome: readsHome,
            screenshotFolder: screenshotFolder,
            package: URL(fileURLWithPath: "/topnotch-test/home/support/Blocks/Hello.topblock"),
            dataFolder: URL(fileURLWithPath: "/topnotch-test/home/support/BlockData/hello"),
            temporaryFolder: URL(fileURLWithPath: "/topnotch-test/shared-tmp/TopNotch/Blocks/hello"),
            sharedTemporaryFolder: URL(fileURLWithPath: "/topnotch-test/shared-tmp"),
            home: URL(fileURLWithPath: "/topnotch-test/home"),
            supportRoot: URL(fileURLWithPath: "/topnotch-test/home/support"),
            preferencesFile: URL(fileURLWithPath: "/topnotch-test/home/Library/Preferences/dev.topnotch.Test.plist"),
            preferenceDomain: "dev.topnotch.Test"
        )
    }

    private func lines(_ profile: SandboxProfile) -> [String] {
        profile.text.split(separator: "\n").map(String.init)
    }

    private let metadataLine = #"(allow file-read-metadata (subpath "/topnotch-test/home"))"#
    private let systemLine = "(allow file-read* " + SandboxProfile.systemReadLocations.joined(separator: " ") + ")"
    private let closeLine = #"(deny file-read* file-write* (subpath "/topnotch-test/shared-tmp/TopNotch") (subpath "/topnotch-test/home/support") (literal "/topnotch-test/home/Library/Preferences/dev.topnotch.Test.plist"))"#
    private let ownLine = #"(allow file-read* file-write* (subpath "/topnotch-test/home/support/BlockData/hello") (subpath "/topnotch-test/shared-tmp/TopNotch/Blocks/hello"))"#
    private let packageLine = #"(allow file-read* (subpath "/topnotch-test/home/support/Blocks/Hello.topblock"))"#

    @Test func defaultProfileDeniesNetworkWritesReadsPreferencesAndAppleEvents() {
        let text = lines(profile())
        #expect(text == [
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            #"(deny mach-lookup (global-name "com.apple.dnssd.service"))"#,
            "(deny appleevent-send)",
            "(deny user-preference-write)",
            #"(deny user-preference-read (preference-domain "dev.topnotch.Test"))"#,
            "(deny file-write*)",
            #"(allow file-write* (subpath "/topnotch-test/home/support/BlockData/hello") (subpath "/topnotch-test/shared-tmp") (subpath "/dev"))"#,
            "(deny file-read*)",
            systemLine,
            #"(allow file-read-metadata (subpath "/topnotch-test/shared-tmp"))"#,
            #"(deny file-read-metadata (subpath "/topnotch-test/shared-tmp/TopNotch"))"#,
            #"(allow file-read-metadata (subpath "/topnotch-test/shared-tmp/TopNotch/Blocks/hello"))"#,
            closeLine,
            ownLine,
            packageLine,
            metadataLine,
        ])
    }

    /// The system locations are the ones the spike measured
    /// (`spikes/FINDINGS.md`, "Sandbox rules, 21 Nov").
    @Test func theProfileDeniesReadsThenAllowsTheListedPlaces() {
        let text = lines(profile())
        let deny = text.firstIndex(of: "(deny file-read*)")
        let system = text.firstIndex(of: systemLine)
        let own = text.firstIndex(of: ownLine)
        #expect(deny != nil && system != nil && own != nil)
        if let deny, let system, let own {
            #expect(deny < system)
            #expect(system < own)
            // No read allow comes before the deny.
            #expect(!text[..<deny].contains { $0.hasPrefix("(allow file-read") })
        }
        #expect(SandboxProfile.systemReadLocations == [
            #"(literal "/")"#, #"(literal "/etc")"#, #"(literal "/var")"#, #"(literal "/tmp")"#,
            #"(subpath "/System")"#, #"(subpath "/usr")"#, #"(subpath "/bin")"#, #"(subpath "/sbin")"#,
            #"(subpath "/Library/Apple")"#, #"(subpath "/Library/Preferences")"#, #"(subpath "/private/etc")"#,
            #"(subpath "/private/var/db/timezone")"#, #"(subpath "/private/var/db/dyld")"#,
            #"(subpath "/private/var/db/eligibilityd")"#, #"(subpath "/dev")"#,
        ])
        // Neither the home folder nor the shared temporary folder is read-allowed.
        #expect(!text.contains(#"(allow file-read* (subpath "/topnotch-test/home"))"#))
        #expect(!text.contains { $0.hasPrefix("(allow file-read*") && $0.contains(#"(subpath "/topnotch-test/shared-tmp")"#) })
    }

    /// The app's `TopNotch` subtree of the temporary folder, TopNotch's
    /// support folder and the preferences file are closed after every
    /// allow; each block reads and writes only its own folders inside them.
    /// SBPL: the later rule wins, so the own folders' allow comes after the
    /// deny, which comes after the write allow of the whole temporary folder.
    @Test func topNotchsFoldersAreDeniedLastAndTheBlocksOwnAllowedAfter() {
        let text = lines(profile())
        let write = text.firstIndex { $0.hasPrefix("(allow file-write*") && $0.contains(#"(subpath "/topnotch-test/shared-tmp")"#) }
        let deny = text.firstIndex(of: closeLine)
        let own = text.firstIndex(of: ownLine)
        let package = text.firstIndex(of: packageLine)
        #expect(write != nil && deny != nil && own != nil && package != nil)
        if let write, let deny, let own, let package {
            #expect(write < deny)
            #expect(deny < own)
            #expect(deny < package)
        }
        // Every token keeps the rules, and adds its allow before the deny.
        for changed in [profile(gatePort: 4321), profile(readsHome: true),
                        profile(screenshotFolder: URL(fileURLWithPath: "/topnotch-test/home/Desktop"))] {
            let changed = lines(changed)
            #expect(changed.filter { $0.contains("shared-tmp") } == text.filter { $0.contains("shared-tmp") })
            let tokenAllows = changed.indices.filter { changed[$0].hasPrefix("(allow file-read*") && !text.contains(changed[$0]) }
            let close = changed.firstIndex(of: closeLine)
            #expect(close != nil)
            if let close { #expect(tokenAllows.allSatisfy { $0 < close }) }
        }
    }

    /// With a gate the network deny stays, and only the gate's local port
    /// is allowed after it. Name lookups stay closed either way.
    @Test func aGatePortAllowsOnlyThatLocalPort() {
        let base = lines(profile())
        let changed = lines(profile(gatePort: 4321))
        let deny = changed.firstIndex(of: "(deny network*)")
        let allow = changed.firstIndex(of: #"(allow network-outbound (remote tcp "localhost:4321"))"#)
        #expect(deny != nil && allow != nil)
        if let deny, let allow { #expect(deny < allow) }
        #expect(changed.filter { !base.contains($0) } == [#"(allow network-outbound (remote tcp "localhost:4321"))"#])
        #expect(base.allSatisfy { changed.contains($0) })
        #expect(!base.contains { $0.hasPrefix("(allow network") })
        for text in [base, changed] {
            #expect(text.contains(#"(deny mach-lookup (global-name "com.apple.dnssd.service"))"#))
        }
    }

    /// Preferences: no writes to any domain, no reads of the app's own (D29).
    @Test func thePreferenceServiceIsClosedForTheAppsDomain() {
        for text in [lines(profile()), lines(profile(readsHome: true)), lines(profile(gatePort: 1))] {
            #expect(text.contains("(deny user-preference-write)"))
            #expect(text.contains(#"(deny user-preference-read (preference-domain "dev.topnotch.Test"))"#))
            #expect(!text.contains { $0.hasPrefix("(allow user-preference") })
        }
    }

    /// `files.read` opens the home folder and other volumes (`/Volumes`), as
    /// before the read allow-list; the deny of TopNotch's folders follows,
    /// so it wins even when the home folder is on another volume.
    @Test func filesReadOpensHomeButNotTopNotchsFolders() {
        let base = lines(profile())
        let changed = lines(profile(readsHome: true))
        let homeAllow = #"(allow file-read* (subpath "/topnotch-test/home") (subpath "/Volumes"))"#
        #expect(changed.filter { !base.contains($0) } == [homeAllow])
        #expect(base.allSatisfy { changed.contains($0) })
        let home = changed.firstIndex(of: homeAllow)
        let close = changed.firstIndex(of: closeLine)
        let readDeny = changed.firstIndex(of: "(deny file-read*)")
        #expect(home != nil && close != nil && readDeny != nil)
        if let home, let close, let readDeny {
            #expect(readDeny < home)
            #expect(home < close)
        }
        #expect(changed.contains(metadataLine))
    }

    @Test func screenshotsTokenAllowsReadAndWriteInThatFolderOnly() {
        let base = lines(profile())
        let changed = lines(profile(screenshotFolder: URL(fileURLWithPath: "/topnotch-test/home/Desktop")))
        let screenshotAllow = #"(allow file-read* file-write* (subpath "/topnotch-test/home/Desktop"))"#
        #expect(changed.filter { !base.contains($0) } == [screenshotAllow])
        #expect(base.allSatisfy { changed.contains($0) })
        #expect(changed.last == metadataLine)
        let allow = changed.firstIndex(of: screenshotAllow)
        let close = changed.firstIndex(of: closeLine)
        #expect(allow != nil && close != nil)
        if let allow, let close { #expect(allow < close, "the screenshot folder never reopens TopNotch's folders") }
    }

    // MARK: allowsRead

    @Test func allowsReadFollowsTheProfile() {
        let plain = profile()
        #expect(plain.allowsRead("/topnotch-test/home/support/BlockData/hello/own.png"))
        #expect(plain.allowsRead("/topnotch-test/home/support/Blocks/Hello.topblock/Contents/Info.plist"))
        #expect(plain.allowsRead("/topnotch-test/shared-tmp/TopNotch/Blocks/hello/a.png"))
        #expect(plain.allowsRead("/System/Library/CoreServices/SystemVersion.plist"))
        #expect(!plain.allowsRead("relative.png"))
        #expect(!plain.allowsRead("/topnotch-test/home/Documents/note"))
        #expect(!plain.allowsRead("/topnotch-test/shared-tmp/other-app.png"), "the shared temporary folder is not readable")
        #expect(!plain.allowsRead("/topnotch-test/shared-tmp/TopNotch/Blocks/other/a.png"))
        #expect(!plain.allowsRead("/topnotch-test/home/support/BlockData/hello-other/a.png"))

        let reading = profile(readsHome: true)
        #expect(reading.allowsRead("/topnotch-test/home/Documents/note"))
        #expect(reading.allowsRead("/Volumes/Disk/file"))
        #expect(!reading.allowsRead("/topnotch-test/home/support/Approvals.json"))
        #expect(!reading.allowsRead("/topnotch-test/home/support/BlockData/other/secret"))
        #expect(!reading.allowsRead("/topnotch-test/home/Library/Preferences/dev.topnotch.Test.plist"))
        #expect(!reading.allowsRead("/topnotch-test/shared-tmp/TopNotch/Drops/UUID/drop.png"))
        #expect(!reading.allowsRead("/topnotch-test/shared-tmp/other-app.png"))

        let screenshots = profile(screenshotFolder: URL(fileURLWithPath: "/topnotch-test/home"))
        #expect(screenshots.allowsRead("/topnotch-test/home/Desktop/Screenshot.png"))
        #expect(!screenshots.allowsRead("/topnotch-test/home/support/Approvals.json"))
        #expect(!screenshots.allowsRead("/topnotch-test/home/Library/Preferences/dev.topnotch.Test.plist"))
    }

    /// A1: a screenshot folder set to the home folder contains TopNotch's
    /// support folder and the preferences file; neither opens, for reads or writes.
    @Test func aScreenshotFolderAtHomeKeepsTopNotchsFoldersClosed() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = try makeFolders(in: root, data: "home/support/BlockData/probe")
        var profile = folders.profile()
        profile.screenshotFolder = folders.home
        let approvals = folders.support.appending(path: "Approvals.json")
        try Data("{}".utf8).write(to: approvals)
        let preferences = folders.home.appending(path: "Library/Preferences/dev.topnotch.Test.plist")
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: preferences)
        let drops = folders.shared.appending(path: "TopNotch/Drops")
        try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: true)
        let dropped = drops.appending(path: "dropped")
        try Data("x".utf8).write(to: dropped)
        let screenshot = folders.home.appending(path: "Screenshot.png")
        try Data("x".utf8).write(to: screenshot)

        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/bin/cat", approvals.path]) != 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", approvals.path]) != 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", folders.support.appending(path: "new").path]) != 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/bin/cat", preferences.path]) != 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/bin/cat", dropped.path]) != 0)
        // The screenshot folder itself and the block's own data stay open.
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/bin/cat", screenshot.path]) == 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", folders.home.appending(path: "Renamed.png").path]) == 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", folders.data.appending(path: "own").path]) == 0)
        #expect(!profile.allowsRead(approvals.path))
        #expect(profile.allowsRead(screenshot.path))
    }

    @Test func profileRunsUnderSandboxExec() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = try makeFolders(in: root, data: "data")
        let profile = folders.profile()

        let allowed = folders.data.appending(path: "allowed")
        let refused = folders.home.appending(path: "refused")
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", allowed.path]) == 0)
        #expect(FileManager.default.fileExists(atPath: allowed.path))
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", refused.path]) != 0)
        #expect(!FileManager.default.fileExists(atPath: refused.path))

        // The app's subtree of the temporary folder is closed; the block's own
        // folder in it is open; the rest of the temporary folder stays
        // writable but not readable.
        let drops = folders.shared.appending(path: "TopNotch/Drops")
        try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: true)
        let dropped = drops.appending(path: "dropped")
        try Data("x".utf8).write(to: dropped)
        let otherApp = folders.shared.appending(path: "other-app")
        try Data("x".utf8).write(to: otherApp)
        let own = folders.temporary.appending(path: "own")
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/bin/cat", dropped.path]) != 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", drops.appending(path: "new").path]) != 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/bin/cat", otherApp.path]) != 0)
        // Metadata of the shared folder is readable (Foundation needs it to
        // write there), but not listings, and nothing in the app's subtree.
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/bin/ls", folders.shared.path]) != 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/stat", dropped.path]) != 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", folders.shared.appending(path: "new").path]) == 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", own.path]) == 0)
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/bin/cat", own.path]) == 0)
    }

    @Test func pathsWithQuotesAreEscaped() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = try makeFolders(in: root, data: #"da"ta\folder"#)
        let profile = folders.profile()
        #expect(profile.text.contains(#"da\"ta\\folder"#))

        let file = folders.data.appending(path: "written")
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", file.path]) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Helpers

    private struct Folders {
        let home: URL
        let data: URL
        let temporary: URL
        let shared: URL
        let package: URL
        let support: URL

        func profile() -> SandboxProfile {
            SandboxProfile(gatePort: nil, readsHome: false, screenshotFolder: nil,
                           package: package, dataFolder: data,
                           temporaryFolder: temporary, sharedTemporaryFolder: shared, home: home,
                           supportRoot: support, preferencesFile: home.appending(path: "Library/Preferences/dev.topnotch.Test.plist"),
                           preferenceDomain: "dev.topnotch.Test")
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "topnotch-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Sibling folders, so the data folder is not inside the "home" folder;
    /// the block's temporary folder is inside the shared one's `TopNotch`
    /// subtree, as in the app.
    private func makeFolders(in root: URL, data: String) throws -> Folders {
        let shared = root.appending(path: "shared-tmp")
        let folders = Folders(home: root.appending(path: "home"), data: root.appending(path: data),
                              temporary: shared.appending(path: "TopNotch/Blocks/probe"), shared: shared,
                              package: root.appending(path: "Probe.topblock"),
                              support: root.appending(path: "home/support"))
        for folder in [folders.home, folders.data, folders.temporary, folders.package] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folders
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
