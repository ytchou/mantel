import BlockWire
import Foundation
import NotchCore

/// Checks a `.topblock` package before the app runs or installs it. Each
/// refusal is one `BlockInstallError` case whose text tells the owner what
/// to do next.
enum PackageValidator {
    /// Ids that belong to blocks built into the app, the app's own key
    /// prefixes (`block`, `onboarding`), and prefixes of common UserDefaults
    /// keys (`com`, `apple`, `ns`) that Remove, which clears `<id>.*`, must
    /// not touch. Only a bundled package may use one (now-playing ships that way).
    // Hand-kept: a new built-in block or app key prefix must be added here by
    // hand. Fine while the built-in blocks are a short list fixed at compile
    // time; if they grow or become dynamic, build this set from the built-in
    // blocks' ids plus the fixed prefixes, in one place the app also reads.
    static let reservedIDs: Set<String> = [
        "shelf", "rename", "demo", "nowplaying", "block", "onboarding", "com", "apple", "ns",
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
    static func load(_ package: URL, source: BlockSource) throws(BlockInstallError) -> Manifest {
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
        try validate(manifest, package: package, source: source)
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
    static func validate(_ manifest: Manifest, package: URL, source: BlockSource) throws(BlockInstallError) {
        guard Contract.supported.contains(manifest.contract) else {
            throw .unsupportedContract(found: manifest.contract, supported: Contract.supported)
        }
        try checkID(manifest.id, source: source)
        try checkExecutable(manifest.executable, package: package)
        if let unknown = manifest.events.first(where: { WireEvent(rawValue: $0) == nil }) {
            throw .unknownEvent(unknown)
        }
        try checkSettings(manifest.settings)
    }

    /// Refuses an id that is not `[a-z0-9-]+`, or that is reserved and the
    /// source is not bundled.
    static func checkID(_ id: String, source: BlockSource) throws(BlockInstallError) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !id.isEmpty, id.allSatisfy(allowed.contains) else { throw .invalidID(id) }
        switch source {
        case .builtIn, .bundled:
            return
        case .installed, .development:
            if reservedIDs.contains(id) { throw .reservedID(id) }
        }
    }

    private static func checkExecutable(_ path: String, package: URL) throws(BlockInstallError) {
        func isInside(_ child: URL, _ parent: URL) -> Bool {
            let root = parent.path
            return child.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        let folder = executableFolder(in: package)
        let executable = folder.appending(path: path)
        let resolved = executable.standardizedFileURL.path
        // `appending(path:)` treats a leading "/" as relative, so an absolute
        // path is refused on its own. The path is checked as written, then
        // with symbolic links followed, so a link cannot lead outside
        // `Contents/MacOS`.
        guard !path.hasPrefix("/"),
              isInside(executable.standardizedFileURL, folder.standardizedFileURL),
              isInside(executable.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
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
