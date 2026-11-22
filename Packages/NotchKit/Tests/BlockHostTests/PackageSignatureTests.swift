import Foundation
import Testing
@testable import BlockHost

/// Builds a minimal bundle around a copy of `/usr/bin/true` in a temporary
/// folder. The tests sign ad hoc only.
// Built here, not with `Packages/BlockKit/Scripts/package-block.sh`: the
// bundle shape is the same (Info.plist, MacOS/<executable>,
// Resources/manifest.json); switch to the script once its bundle format settles.
@Suite
struct PackageSignatureTests {
    @Test func adHocSignedBundleIsValidAndAdHoc() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        try signAdHoc(bundle)

        #expect(PackageSignature.check(bundle) == .adHoc)
        #expect(SystemSignatureChecker().check(bundle) == .adHoc)
    }

    @Test func unsignedBundleIsUnsigned() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        #expect(PackageSignature.check(bundle) == .unsigned)
    }

    @Test func changedManifestFailsValidation() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        try signAdHoc(bundle)
        try Data(#"{"id":"probe","changed":true}"#.utf8)
            .write(to: bundle.appending(path: "Contents/Resources/manifest.json"))

        let result = PackageSignature.check(bundle)
        guard case let .invalid(reason) = result else {
            Issue.record("Expected .invalid, got \(result)")
            return
        }
        #expect(!reason.isEmpty)
    }

    // MARK: - Helpers

    /// `<temp>/Probe.mantelblock` with an executable whose signature is removed.
    private func makeBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "mantel-signature-\(UUID().uuidString)")
        let bundle = root.appending(path: "Probe.mantelblock")
        let contents = bundle.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        let resources = contents.appending(path: "Resources")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleExecutable": "Probe",
            "CFBundleIdentifier": "com.example.mantel.probe",
            "CFBundleName": "Probe",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))

        let executable = macOS.appending(path: "Probe")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try #require(run(["--remove-signature", executable.path]) == 0)

        try Data(#"{"id":"probe"}"#.utf8).write(to: resources.appending(path: "manifest.json"))
        return bundle
    }

    private func signAdHoc(_ bundle: URL) throws {
        try #require(run(["--force", "--sign", "-", bundle.path]) == 0)
    }

    private func run(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
