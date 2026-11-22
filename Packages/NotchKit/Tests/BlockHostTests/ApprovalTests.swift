import Foundation
import NotchCore
import Testing
@testable import BlockHost

@Suite
struct ApprovalTests {
    @Test func theHashCoversEveryFileInThePackage() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makePackage(in: root, named: "Probe.mantelblock")
        let before = PackageHash.of(package)

        // Neither the executable nor the manifest: a library beside them.
        let library = package.appending(path: "Contents/Frameworks/libProbe.dylib")
        var bytes = try Data(contentsOf: library)
        bytes[0] ^= 0x01
        try bytes.write(to: library)

        #expect(PackageHash.of(package) != before)
        #expect(PackageHash.of(package).count == 64)
    }

    @Test func theHashIgnoresFolderNameAndFileDates() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makePackage(in: root, named: "Probe.mantelblock")
        let copy = root.appending(path: "Renamed.mantelblock")
        try FileManager.default.copyItem(at: package, to: copy)
        let later = Date(timeIntervalSinceNow: 86_400)
        for path in try FileManager.default.subpathsOfDirectory(atPath: copy.path) {
            try FileManager.default.setAttributes(
                [.modificationDate: later, .creationDate: later],
                ofItemAtPath: copy.appending(path: path).path
            )
        }

        #expect(PackageHash.of(copy) == PackageHash.of(package))
    }

    @Test func anApprovalIsFoundAgainAfterReload() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Approvals.json")
        let store = ApprovalStore(file: file)
        try store.approve(id: "weather-peek", hash: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", signer: "Example Signer", hosts: ["api.example.com"])
        try store.approve(id: "clip-stash", hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", signer: nil, hosts: [])

        let reloaded = ApprovalStore(file: file)

        #expect(reloaded.approval(for: "weather-peek")
            == Approval(id: "weather-peek", hash: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", signer: "Example Signer", hosts: ["api.example.com"]))
        #expect(reloaded.approval(for: "clip-stash") == Approval(id: "clip-stash", hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", signer: nil, hosts: []))
        #expect(reloaded.approval(for: "timer") == nil)
    }

    @Test func eventsRoundTripAndAnOldRecordHasNone() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Approvals.json")
        try ApprovalStore(file: file).approve(id: "screenshots", hash: String(repeating: "a", count: 64), signer: nil,
                                              hosts: [], events: ["screenshotCaptured", "pointerHover"])

        #expect(ApprovalStore(file: file).approval(for: "screenshots")?.events == ["screenshotCaptured", "pointerHover"])

        // As written before events were kept.
        let old = #"{"older":{"hash":"\#(String(repeating: "b", count: 64))","hosts":["api.example.com"]}}"#
        try Data(old.utf8).write(to: file)
        let approval = try #require(ApprovalStore(file: file).approval(for: "older"))
        #expect(approval.events == [])
        #expect(approval.hosts == ["api.example.com"])
        #expect(approval.signer == nil)
    }

    /// A4: what the app cannot read cannot be compared, so it matches no approval.
    @Test func anUnreadableFileMatchesNoApproval() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makePackage(in: root, named: "Probe.mantelblock")
        let approved = PackageHash.of(package)
        let library = package.appending(path: "Contents/Frameworks/libProbe.dylib")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: library.path) }

        let first = PackageHash.of(package)
        #expect(first != approved)
        #expect(PackageHash.of(package) != first, "two reads of an unreadable package never agree")
    }

    @Test func anUnlistableFolderMatchesNoApproval() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makePackage(in: root, named: "Probe.mantelblock")
        let approved = PackageHash.of(package)
        let folder = package.appending(path: "Contents/Frameworks")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        #expect(PackageHash.of(package) != approved)
        #expect(PackageHash.of(package) != PackageHash.of(package))
    }

    @Test func aMissingPackageMatchesNoApproval() {
        let missing = temporaryFolder().appending(path: "Gone.mantelblock")
        #expect(PackageHash.of(missing) != PackageHash.of(missing))
    }

    @Test func removingAnApprovalDeletesIt() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Approvals.json")
        let store = ApprovalStore(file: file)
        try store.approve(id: "weather-peek", hash: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", signer: nil, hosts: [])
        try store.approve(id: "clip-stash", hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", signer: nil, hosts: [])

        try store.remove(id: "weather-peek")

        #expect(ApprovalStore(file: file).approval(for: "weather-peek") == nil)
        #expect(ApprovalStore(file: file).approval(for: "clip-stash") != nil)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("weather-peek"))
    }

    @Test func aMissingOrDamagedFileMeansNoApprovals() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Approvals.json")

        #expect(ApprovalStore(file: file).approval(for: "weather-peek") == nil)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json {".utf8).write(to: file)
        let damaged = ApprovalStore(file: file)
        #expect(damaged.approval(for: "weather-peek") == nil)

        // A damaged file is replaced by the next approval, not a crash.
        try damaged.approve(id: "clip-stash", hash: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", signer: nil, hosts: [])
        #expect(ApprovalStore(file: file).approval(for: "clip-stash") != nil)
    }

    // MARK: - Helpers

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "mantel-approval-\(UUID().uuidString)")
    }

    /// `<root>/<name>` with an executable, a manifest, a library and a
    /// symbolic link.
    private func makePackage(in root: URL, named name: String) throws -> URL {
        let package = root.appending(path: name)
        let contents = package.appending(path: "Contents")
        for folder in ["MacOS", "Resources", "Frameworks"] {
            try FileManager.default.createDirectory(
                at: contents.appending(path: folder), withIntermediateDirectories: true
            )
        }
        try Data("executable".utf8).write(to: contents.appending(path: "MacOS/Probe"))
        try Data(#"{"id":"probe"}"#.utf8).write(to: contents.appending(path: "Resources/manifest.json"))
        try Data("library".utf8).write(to: contents.appending(path: "Frameworks/libProbe.dylib"))
        try FileManager.default.createSymbolicLink(
            atPath: contents.appending(path: "Frameworks/Current").path,
            withDestinationPath: "libProbe.dylib"
        )
        return package
    }
}
