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

    /// A temporary `<Name>.topblock` bundle holding `manifest` and, unless
    /// told otherwise, an executable file at `Contents/MacOS/<manifest.executable>`.
    private func package(
        _ manifest: Manifest,
        writeExecutable: Bool = true,
        executableMode: Int = 0o755
    ) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "topnotch-validator-\(UUID().uuidString)")
            .appending(path: "Test.topblock")
        try writeBundle(at: folder, manifest: manifest, writeExecutable: writeExecutable, mode: executableMode)
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
        #expect(text.contains("supports contracts 1 to 2"))
    }

    @Test func refusesReservedIds() throws {
        // `com`, `apple` and `ns` start common UserDefaults keys, which Remove would clear.
        for id in ["shelf", "rename", "demo", "nowplaying", "block", "onboarding", "com", "apple", "ns"] {
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
        // `../x` stays in the package but leaves `Contents/MacOS`.
        for path in ["../x", "/bin/sh", "bin/../../x", "../../../x"] {
            let error = try refusal(manifest(executable: path), writeExecutable: false)
            #expect(error == .executableOutsidePackage(path), "\(path) leaves the package")
        }
    }

    @Test func refusesSymlinkLeadingOutsidePackage() throws {
        // The executable is a link to a program outside the package.
        let linked = try package(manifest(executable: "HelloBlock"), writeExecutable: false)
        try FileManager.default.createSymbolicLink(at: macOS(linked).appending(path: "HelloBlock"),
                                                   withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        #expect(throws: BlockInstallError.executableOutsidePackage("HelloBlock")) {
            try PackageValidator.load(linked, source: Self.installed)
        }

        // A folder in the path is a link to a folder outside the package.
        let throughFolder = try package(manifest(executable: "bin/sh"), writeExecutable: false)
        try FileManager.default.createSymbolicLink(at: macOS(throughFolder).appending(path: "bin"),
                                                   withDestinationURL: URL(fileURLWithPath: "/bin"))
        #expect(throws: BlockInstallError.executableOutsidePackage("bin/sh")) {
            try PackageValidator.load(throughFolder, source: Self.installed)
        }

        // A link that stays inside the package is fine.
        let inside = try package(manifest(executable: "Link"), writeExecutable: false)
        let real = macOS(inside).appending(path: "Real")
        try Data("#!/bin/sh\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(atPath: macOS(inside).appending(path: "Link").path, withDestinationPath: "Real")
        #expect(throws: Never.self) { try PackageValidator.load(inside, source: Self.installed) }
    }

    @Test func refusesDefaultThatDoesNotMatchType() throws {
        let stringToggle = manifest(settings: [SettingSpec(key: "loud", type: .toggle, title: "Loud", default: .string("yes"))])
        #expect(try refusal(stringToggle) == .invalidSetting("loud"))

        let options: [SettingSpec.Option] = [.init(value: "large", title: "Large")]
        let unknownChoice = manifest(settings: [SettingSpec(key: "size", type: .choice, title: "Size",
                                                            default: .string("medium"), options: options)])
        #expect(try refusal(unknownChoice) == .invalidSetting("size"))

        let boolChoice = manifest(settings: [SettingSpec(key: "size", type: .choice, title: "Size",
                                                         default: .bool(true), options: options)])
        #expect(try refusal(boolChoice) == .invalidSetting("size"))

        let valid = manifest(settings: [
            SettingSpec(key: "loud", type: .toggle, title: "Loud", default: .bool(false)),
            SettingSpec(key: "size", type: .choice, title: "Size", default: .string("large"), options: options),
        ])
        #expect(try refusal(valid) == nil)
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

    @Test func flatPackageIsRefusedAsOldFormat() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "topnotch-validator-\(UUID().uuidString)")
            .appending(path: "Flat.topblock")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hello = manifest()
        try Framing.encoder().encode(hello).write(to: folder.appending(path: "manifest.json"))
        let executable = folder.appending(path: hello.executable)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        #expect(throws: BlockInstallError.oldPackageFormat) { try PackageValidator.load(folder, source: Self.installed) }
        #expect(try #require(BlockInstallError.oldPackageFormat.errorDescription).contains("package-block.sh"))
    }

    @Test func unknownAccessTokenIsRefused() throws {
        let url = try package(manifest())
        let manifestFile = url.appending(path: "Contents/Resources/manifest.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any])
        object["access"] = ["network", "camera"]
        try JSONSerialization.data(withJSONObject: object).write(to: manifestFile)

        #expect(throws: BlockInstallError.unknownAccess("camera")) { try PackageValidator.load(url, source: Self.installed) }

        // Known tokens pass.
        object["access"] = ["network", "files.read", "files.screenshots"]
        try JSONSerialization.data(withJSONObject: object).write(to: manifestFile)
        let loaded = try PackageValidator.load(url, source: Self.installed)
        #expect(loaded.access == [.network, .filesRead, .filesScreenshots])
    }

    private func macOS(_ package: URL) -> URL {
        package.appending(path: "Contents/MacOS")
    }
}
