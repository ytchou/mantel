import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

/// Every package is built in a temporary folder; the real Application Support
/// folder is never touched.
struct PackageValidatorTests {
    /// The kit's example manifest, read from the repository.
    private static let helloManifestURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // BlockHostTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // NotchKit
        .deletingLastPathComponent() // Packages
        .appending(path: "BlockKit/Examples/HelloBlock/manifest.json")

    private static let installed = BlockSource.installed(from: "/tmp/Hello.topblock")

    /// A temporary `<Name>.topblock` holding `manifest` and, unless told
    /// otherwise, an executable file at `manifest.executable`.
    private func package(
        _ manifest: Manifest,
        writeExecutable: Bool = true,
        executableMode: Int = 0o755
    ) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "topnotch-validator-\(UUID().uuidString)")
            .appending(path: "Test.topblock")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Framing.encoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
        if writeExecutable {
            let executable = folder.appending(path: manifest.executable)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: executableMode], ofItemAtPath: executable.path)
        }
        return folder
    }

    private func manifest(
        id: String = "hello",
        contract: Int = Contract.current,
        executable: String = "HelloBlock",
        events: [String] = ["pointerHover"],
        settings: [SettingSpec] = []
    ) -> Manifest {
        Manifest(id: id, name: "Hello", version: "1.0.0", contract: contract, executable: executable,
                 events: events, settings: settings)
    }

    /// The refusal for `manifest` in a package, or `nil` when it passes.
    private func refusal(
        _ manifest: Manifest,
        source: BlockSource = PackageValidatorTests.installed,
        writeExecutable: Bool = true,
        executableMode: Int = 0o755
    ) throws -> BlockInstallError? {
        let url = try package(manifest, writeExecutable: writeExecutable, executableMode: executableMode)
        do {
            _ = try PackageValidator.load(url, source: source)
            return nil
        } catch {
            return error
        }
    }

    @Test func acceptsValidPackage() throws {
        let hello = try Manifest.decode(Data(contentsOf: Self.helloManifestURL))
        let url = try package(hello)

        let loaded = try PackageValidator.load(url, source: Self.installed)

        #expect(loaded == hello)
    }

    @Test func refusesUnsupportedContract() throws {
        let error = try #require(try refusal(manifest(contract: 99)))

        #expect(error == .unsupportedContract(found: 99, supported: Contract.supported))
        let text = try #require(error.errorDescription)
        #expect(text.contains("contract 99"))
        #expect(text.contains("supports contract 1"))
    }

    @Test func refusesReservedIds() throws {
        for id in ["shelf", "rename", "demo", "nowplaying", "block", "onboarding"] {
            #expect(try refusal(manifest(id: id)) == .reservedID(id), "\(id) is reserved for installed blocks")
            #expect(try refusal(manifest(id: id), source: .development(path: "/tmp/Test.topblock")) == .reservedID(id),
                    "\(id) is reserved for development blocks")
        }
        #expect(try refusal(manifest(id: "nowplaying"), source: .bundled) == nil, "the bundled now-playing block passes")
        let text = try #require(BlockInstallError.reservedID("shelf").errorDescription)
        #expect(text.contains("\"shelf\""))
    }

    @Test func refusesBadIdCharacters() throws {
        for id in ["Hello World", "a/b", "", "Hello", "a_b"] {
            #expect(try refusal(manifest(id: id)) == .invalidID(id), "\"\(id)\" is not a valid id")
        }
        #expect(try refusal(manifest(id: "hello-2")) == nil)
    }

    @Test func refusesExecutableOutsidePackage() throws {
        for path in ["../x", "/bin/sh", "bin/../../x"] {
            let error = try refusal(manifest(executable: path), writeExecutable: false)
            #expect(error == .executableOutsidePackage(path), "\(path) leaves the package")
        }
    }

    @Test func refusesMissingOrNonExecutableFile() throws {
        let missing = try #require(try refusal(manifest(executable: "Missing"), writeExecutable: false))
        #expect(missing == .executableMissing("Missing"))
        #expect(try #require(missing.errorDescription).contains("\"Missing\""))

        let plain = try refusal(manifest(executable: "Plain"), executableMode: 0o644)
        #expect(plain == .executableMissing("Plain"))
    }

    @Test func refusesUnknownEventName() throws {
        let error = try #require(try refusal(manifest(events: ["pointerHover", "keyPressed"])))

        #expect(error == .unknownEvent("keyPressed"))
        #expect(try #require(error.errorDescription).contains("\"keyPressed\""))
    }

    @Test func refusesSettingKeyCollisions() throws {
        let duplicate = manifest(settings: [
            SettingSpec(key: "loud", type: .toggle, title: "Loud"),
            SettingSpec(key: "loud", type: .toggle, title: "Louder"),
        ])
        #expect(try refusal(duplicate) == .invalidSetting("loud"))

        let noOptions = manifest(settings: [SettingSpec(key: "size", type: .choice, title: "Size")])
        #expect(try refusal(noOptions) == .invalidSetting("size"))

        let emptyOptions = manifest(settings: [SettingSpec(key: "size", type: .choice, title: "Size", options: [])])
        #expect(try refusal(emptyOptions) == .invalidSetting("size"))

        let untitledNote = manifest(settings: [SettingSpec(key: "about", type: .note, title: "")])
        #expect(try refusal(untitledNote) == .invalidSetting("about"))

        let valid = manifest(settings: [
            SettingSpec(key: "loud", type: .toggle, title: "Loud"),
            SettingSpec(key: "size", type: .choice, title: "Size", options: [.init(value: "large", title: "Large")]),
            SettingSpec(key: "about", type: .note, title: "A note"),
        ])
        #expect(try refusal(valid) == nil)
    }

    @Test func refusesUnreadableManifest() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "topnotch-validator-\(UUID().uuidString)")
            .appending(path: "Empty.topblock")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(throws: BlockInstallError.self) { try PackageValidator.load(folder, source: Self.installed) }
    }
}
