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
    private let ownReadsLine = #"(allow file-read* (subpath "/topnotch-test/home/support/BlockData/hello") (subpath "/topnotch-test/home/support/Blocks/Hello.topblock") (subpath "/topnotch-test/shared-tmp/TopNotch/Blocks/hello"))"#

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
            #"(deny file-read* file-write* (subpath "/topnotch-test/shared-tmp/TopNotch"))"#,
            #"(allow file-read* file-write* (subpath "/topnotch-test/shared-tmp/TopNotch/Blocks/hello"))"#,
            "(deny file-read*)",
            systemLine,
            #"(allow file-read-metadata (subpath "/topnotch-test/shared-tmp"))"#,
            #"(deny file-read-metadata (subpath "/topnotch-test/shared-tmp/TopNotch"))"#,
            #"(allow file-read-metadata (subpath "/topnotch-test/shared-tmp/TopNotch/Blocks/hello"))"#,
            ownReadsLine,
            metadataLine,
        ])
    }

    /// The system locations are the ones the spike measured
    /// (`spikes/FINDINGS.md`, "Sandbox rules, 21 Nov").
    @Test func theProfileDeniesReadsThenAllowsTheListedPlaces() {
        let text = lines(profile())
        let deny = text.firstIndex(of: "(deny file-read*)")
        let system = text.firstIndex(of: systemLine)
        let own = text.firstIndex(of: ownReadsLine)
        #expect(deny != nil && system != nil && own != nil)
        if let deny, let system, let own {
            #expect(deny < system)
            #expect(system < own)
            // No read allow comes before the deny, except the block's own
            // temporary folder, which the deny then narrows to writes.
            let earlierReadAllows = text[..<deny].filter { $0.hasPrefix("(allow file-read*") }
            #expect(earlierReadAllows == [#"(allow file-read* file-write* (subpath "/topnotch-test/shared-tmp/TopNotch/Blocks/hello"))"#])
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

    /// The app's `TopNotch` subtree of the temporary folder is closed; each
    /// block reads and writes only its own folder inside it. SBPL: the later
    /// rule wins, so the own folder's allow comes after the subtree's deny,
    /// which comes after the write allow of the whole temporary folder.
    @Test func appTemporarySubtreeIsDeniedAndTheBlocksOwnIsAllowedAfter() {
        let text = lines(profile())
        let write = text.firstIndex { $0.hasPrefix("(allow file-write*") && $0.contains(#"(subpath "/topnotch-test/shared-tmp")"#) }
        let deny = text.firstIndex(of: #"(deny file-read* file-write* (subpath "/topnotch-test/shared-tmp/TopNotch"))"#)
        let allow = text.firstIndex(of: #"(allow file-read* file-write* (subpath "/topnotch-test/shared-tmp/TopNotch/Blocks/hello"))"#)
        #expect(write != nil)
        #expect(deny != nil)
        #expect(allow != nil)
        if let write, let deny, let allow {
            #expect(write < deny)
            #expect(deny < allow)
        }
        // Every token keeps both rules.
        for changed in [profile(gatePort: 4321), profile(readsHome: true),
                        profile(screenshotFolder: URL(fileURLWithPath: "/topnotch-test/home/Desktop"))] {
            #expect(lines(changed).filter { $0.contains("shared-tmp") } == text.filter { $0.contains("shared-tmp") })
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
        let supportDeny = #"(deny file-read* (subpath "/topnotch-test/home/support") (literal "/topnotch-test/home/Library/Preferences/dev.topnotch.Test.plist"))"#
        #expect(changed.filter { !base.contains($0) } == [homeAllow, supportDeny])
        #expect(base.allSatisfy { changed.contains($0) })
        let home = changed.firstIndex(of: homeAllow)
        let support = changed.firstIndex(of: supportDeny)
        let own = changed.firstIndex(of: ownReadsLine)
        let readDeny = changed.firstIndex(of: "(deny file-read*)")
        #expect(home != nil && support != nil && own != nil && readDeny != nil)
        if let home, let support, let own, let readDeny {
            #expect(readDeny < home)
            #expect(home < support)
            #expect(support < own)
        }
        #expect(changed.contains(metadataLine))
    }

    @Test func screenshotsTokenAllowsReadAndWriteInThatFolderOnly() {
        let base = lines(profile())
        let changed = lines(profile(screenshotFolder: URL(fileURLWithPath: "/topnotch-test/home/Desktop")))
        let added = changed.filter { !base.contains($0) }
        #expect(added == [#"(allow file-read* file-write* (subpath "/topnotch-test/home/Desktop"))"#])
        #expect(base.allSatisfy { changed.contains($0) })
        #expect(changed.last == metadataLine)
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
