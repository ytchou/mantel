import Foundation
import Testing
@testable import BlockHost

@Suite
struct SandboxProfileTests {
    /// Paths that do not exist, so the builder keeps them as given.
    private func profile(network: Bool = false, readsHome: Bool = false, screenshotFolder: URL? = nil) -> SandboxProfile {
        SandboxProfile(
            network: network,
            readsHome: readsHome,
            screenshotFolder: screenshotFolder,
            package: URL(fileURLWithPath: "/topnotch-test/blocks/Hello.topblock"),
            dataFolder: URL(fileURLWithPath: "/topnotch-test/data/hello"),
            temporaryFolder: URL(fileURLWithPath: "/topnotch-test/tmp"),
            home: URL(fileURLWithPath: "/topnotch-test/home")
        )
    }

    private func lines(_ profile: SandboxProfile) -> [String] {
        profile.text.split(separator: "\n").map(String.init)
    }

    private let metadataLine = #"(allow file-read-metadata (subpath "/topnotch-test/home"))"#

    @Test func defaultProfileDeniesNetworkWritesHomeReadsAndAppleEvents() {
        let text = lines(profile())
        #expect(text == [
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            "(deny appleevent-send)",
            "(deny file-write*)",
            #"(allow file-write* (subpath "/topnotch-test/data/hello") (subpath "/topnotch-test/tmp") (subpath "/dev"))"#,
            #"(deny file-read* (subpath "/topnotch-test/home"))"#,
            #"(allow file-read* (subpath "/topnotch-test/data/hello") (subpath "/topnotch-test/blocks/Hello.topblock"))"#,
            metadataLine,
        ])
    }

    @Test func networkTokenRemovesTheNetworkDeny() {
        let base = lines(profile())
        let changed = lines(profile(network: true))
        #expect(changed == base.filter { $0 != "(deny network*)" })
        #expect(changed.contains(metadataLine))
    }

    @Test func filesReadTokenRemovesTheHomeReadDeny() {
        let base = lines(profile())
        let changed = lines(profile(readsHome: true))
        #expect(changed == base.filter { $0 != #"(deny file-read* (subpath "/topnotch-test/home"))"# })
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
        let profile = SandboxProfile(network: false, readsHome: false, screenshotFolder: nil,
                                     package: folders.package, dataFolder: folders.data,
                                     temporaryFolder: folders.temporary, home: folders.home)

        let allowed = folders.data.appending(path: "allowed")
        let refused = folders.home.appending(path: "refused")
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", allowed.path]) == 0)
        #expect(FileManager.default.fileExists(atPath: allowed.path))
        #expect(try run("/usr/bin/sandbox-exec", ["-p", profile.text, "/usr/bin/touch", refused.path]) != 0)
        #expect(!FileManager.default.fileExists(atPath: refused.path))
    }

    @Test func pathsWithQuotesAreEscaped() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = try makeFolders(in: root, data: #"da"ta\folder"#)
        let profile = SandboxProfile(network: false, readsHome: false, screenshotFolder: nil,
                                     package: folders.package, dataFolder: folders.data,
                                     temporaryFolder: folders.temporary, home: folders.home)
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
        let package: URL
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "topnotch-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Four sibling folders, so the data folder is not inside the "home" folder.
    private func makeFolders(in root: URL, data: String) throws -> Folders {
        let folders = Folders(home: root.appending(path: "home"), data: root.appending(path: data),
                              temporary: root.appending(path: "tmp"), package: root.appending(path: "Probe.topblock"))
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
