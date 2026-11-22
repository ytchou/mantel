import BlockWire
import Foundation
import NotchCore

/// Checks a `.topblock` package before the app runs or installs it. Each
/// refusal is one `BlockInstallError` case whose text tells the owner what
/// to do next.
enum PackageValidator {
    /// The app's own key prefixes (`block`, `onboarding`), and prefixes of
    /// common UserDefaults keys (`com`, `apple`, `ns`) that Remove, which
    /// clears `<id>.*`, must not touch. No package may use one.
    // Hand-kept: a new app key prefix must be added here by hand. Fine while
    // the prefixes are a short list fixed at compile time.
    static let reservedIDs: Set<String> = [
        "block", "onboarding", "com", "apple", "ns",
    ]

    /// The package's `manifest.json`: `Contents/Resources/manifest.json`.
    /// `codesign` seals it with the executable.
    static func manifestURL(in package: URL) -> URL {
        package.appending(path: "Contents/Resources/manifest.json")
    }

    /// The folder the manifest's `executable` is relative to: `Contents/MacOS`.
    static func executableFolder(in package: URL) -> URL {
        package.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
    }

    /// True for a package in the old flat format: `manifest.json` at the
    /// top and no bundle manifest. Refused, with a message to package again.
    static func isOldFormat(_ package: URL) -> Bool {
        !FileManager.default.fileExists(atPath: manifestURL(in: package).path)
            && FileManager.default.fileExists(atPath: package.appending(path: "manifest.json").path)
    }

    /// Reads the package's `manifest.json` and checks it. Returns the manifest
    /// when the package may run. The signature is checked by `BlockStore`.
    static func load(_ package: URL) throws(BlockInstallError) -> Manifest {
        let manifest = try read(package)
        try validate(manifest, package: package)
        return manifest
    }

    /// Reads and decodes the package's `manifest.json`, without `validate`.
    static func read(_ package: URL) throws(BlockInstallError) -> Manifest {
        if isOldFormat(package) { throw .oldPackageFormat }
        let manifest: Manifest
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL(in: package))
        } catch {
            throw .unreadableManifest(error.localizedDescription)
        }
        do throws(ManifestError) {
            manifest = try Manifest.decode(data)
        } catch .invalidField("access") {
            throw unknownAccess(in: data) ?? .unreadableManifest(describe(.invalidField("access")))
        } catch {
            throw .unreadableManifest(describe(error))
        }
        return manifest
    }

    /// The first `access` token this app does not know, as a refusal.
    private static func unknownAccess(in data: Data) -> BlockInstallError? {
        struct Tokens: Decodable { var access: [String] }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data),
              let unknown = tokens.access.first(where: { Access(rawValue: $0) == nil })
        else { return nil }
        return .unknownAccess(unknown)
    }

    /// Checks the meaning of a decoded manifest against its package folder.
    static func validate(_ manifest: Manifest, package: URL) throws(BlockInstallError) {
        guard Contract.supported.contains(manifest.contract) else {
            throw .unsupportedContract(found: manifest.contract, supported: Contract.supported)
        }
        try checkID(manifest.id)
        try checkExecutable(manifest.executable, package: package)
        try checkLinks(in: package)
        if let unknown = manifest.events.first(where: { WireEvent(rawValue: $0) == nil }) {
            throw .unknownEvent(unknown)
        }
        try checkSettings(manifest.settings)
        try checkHosts(manifest)
    }

    /// `network` needs `hosts`, and `hosts` needs `network`, whatever the
    /// contract (D19): a block reaches the network only through the gate,
    /// which lets through the hosts named. Each host is an exact name or
    /// `*.` and a domain; a bare `*` is refused.
    static func checkHosts(_ manifest: Manifest) throws(BlockInstallError) {
        let network = manifest.access.contains(.network)
        if network, manifest.hosts.isEmpty { throw .networkWithoutHosts }
        if !network, !manifest.hosts.isEmpty {
            throw .invalidHosts("it names hosts but does not ask for \"network\"")
        }
        for host in manifest.hosts {
            if let problem = HostRule.problem(with: host) { throw .invalidHosts(problem) }
        }
    }

    /// Refuses an id that is not `[a-z0-9-]+`, or that is reserved.
    static func checkID(_ id: String) throws(BlockInstallError) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !id.isEmpty, id.allSatisfy(allowed.contains) else { throw .invalidID(id) }
        if reservedIDs.contains(id) { throw .reservedID(id) }
    }

    private static func checkExecutable(_ path: String, package: URL) throws(BlockInstallError) {
        func isInside(_ child: URL, _ parent: URL) -> Bool {
            let root = parent.path
            return child.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        let folder = executableFolder(in: package)
        let executable = folder.appending(path: path)
        let resolved = executable.standardizedFileURL.path
        // A file name in `Contents/MacOS`, as `package-block.sh` requires: no
        // "/", and not "", "." or "..". Then, with symbolic links followed,
        // the executable must still be inside the package, so neither a link
        // as the executable nor `Contents/MacOS` itself can lead outside it.
        guard !path.isEmpty, path != ".", path != "..", !path.contains("/"),
              isInside(executable.standardizedFileURL, folder.standardizedFileURL),
              isInside(executable.resolvingSymlinksInPath(), package.resolvingSymlinksInPath())
        else {
            throw .executableOutsidePackage(path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: resolved)
        else {
            throw .executableMissing(path)
        }
    }

    /// Refuses a package with a symbolic link whose target, followed, leaves
    /// the package: the package hash covers a link's text, not what it
    /// points to, so such a target could change after the owner's approval.
    /// A link that points nowhere yet is judged by its text.
    // Reuses the executable refusal: a linked file outside the package is
    // part of the program outside it. A case of its own needs NotchCore's
    // `BlockInstallError`.
    static func checkLinks(in package: URL) throws(BlockInstallError) {
        let manager = FileManager.default
        let root = SandboxProfile.resolvedPath(package)
        for path in manager.subpaths(atPath: package.path) ?? [] {
            let link = package.appending(path: path)
            guard let target = try? manager.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let folder = URL(fileURLWithPath: SandboxProfile.resolvedPath(link.deletingLastPathComponent()), isDirectory: true)
            let pointed = target.hasPrefix("/") ? URL(fileURLWithPath: target) : folder.appending(path: target)
            guard SandboxProfile.isInside(SandboxProfile.resolvedPath(pointed), root) else {
                throw .executableOutsidePackage(path)
            }
        }
    }

    private static func checkSettings(_ settings: [SettingSpec]) throws(BlockInstallError) {
        var seen: Set<String> = []
        for setting in settings {
            guard seen.insert(setting.key).inserted else { throw .invalidSetting(setting.key) }
            switch setting.type {
            case .toggle:
                // The form shows a toggle's default as on or off, so it must be a bool.
                if let value = setting.default, value.bool == nil { throw .invalidSetting(setting.key) }
            case .choice:
                guard let options = setting.options, !options.isEmpty else { throw .invalidSetting(setting.key) }
                if let value = setting.default, !options.contains(where: { $0.value == value.string }) {
                    throw .invalidSetting(setting.key)
                }
            case .note:
                if setting.title.isEmpty { throw .invalidSetting(setting.key) }
            }
        }
    }

    private static func describe(_ error: ManifestError) -> String {
        switch error {
        case let .missingField(field): "the field \"\(field)\" is missing"
        case let .invalidField(field): "the field \"\(field)\" has the wrong type or value"
        case .notJSON: "it is not a JSON object"
        }
    }
}
