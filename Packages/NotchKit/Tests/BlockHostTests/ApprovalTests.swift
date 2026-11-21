import Foundation
import NotchCore
import Testing
@testable import BlockHost

@Suite
struct ApprovalTests {
    @Test func theHashCoversEveryFileInThePackage() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makePackage(in: root, named: "Probe.topblock")
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
        let package = try makePackage(in: root, named: "Probe.topblock")
        let copy = root.appending(path: "Renamed.topblock")
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
        try store.approve(id: "signed", hash: "abc", signer: "Example Signer", hosts: ["api.example.com"])
        try store.approve(id: "unsigned", hash: "def", signer: nil, hosts: [])

        let reloaded = ApprovalStore(file: file)

        #expect(reloaded.approval(for: "signed")
            == Approval(id: "signed", hash: "abc", signer: "Example Signer", hosts: ["api.example.com"]))
        #expect(reloaded.approval(for: "unsigned") == Approval(id: "unsigned", hash: "def", signer: nil, hosts: []))
        #expect(reloaded.approval(for: "other") == nil)
    }

    @Test func removingAnApprovalDeletesIt() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Approvals.json")
        let store = ApprovalStore(file: file)
        try store.approve(id: "gone", hash: "abc", signer: nil, hosts: [])
        try store.approve(id: "kept", hash: "def", signer: nil, hosts: [])

        try store.remove(id: "gone")

        #expect(ApprovalStore(file: file).approval(for: "gone") == nil)
        #expect(ApprovalStore(file: file).approval(for: "kept") != nil)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("gone"))
    }

    @Test func aMissingOrDamagedFileMeansNoApprovals() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Approvals.json")

        #expect(ApprovalStore(file: file).approval(for: "any") == nil)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json {".utf8).write(to: file)
        let damaged = ApprovalStore(file: file)
        #expect(damaged.approval(for: "any") == nil)

        // A damaged file is replaced by the next approval, not a crash.
        try damaged.approve(id: "fresh", hash: "abc", signer: nil, hosts: [])
        #expect(ApprovalStore(file: file).approval(for: "fresh") != nil)
    }

    // MARK: - Helpers

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "topnotch-approval-\(UUID().uuidString)")
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
