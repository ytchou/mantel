import BlockWire
import Foundation
import NotchCore

/// Checks a `.topblock` package before the app runs or installs it. Each
/// refusal is one `BlockInstallError` case whose text tells the owner what
/// to do next.
enum PackageValidator {
    /// Ids that belong to blocks built into the app, and the `block` settings
    /// prefix. Only a bundled package may use one (now-playing ships that way).
    static let reservedIDs: Set<String> = ["shelf", "rename", "demo", "nowplaying", "block", "onboarding"]

    /// Reads `manifest.json` in `package` and checks it. Returns the manifest
    /// when the package may run.
    static func load(_ package: URL, source: BlockSource) throws(BlockInstallError) -> Manifest {
        let manifest: Manifest
        do {
            let data = try Data(contentsOf: package.appending(path: "manifest.json"))
            manifest = try Manifest.decode(data)
        } catch let error as ManifestError {
            throw .unreadableManifest(describe(error))
        } catch {
            throw .unreadableManifest(error.localizedDescription)
        }
        try validate(manifest, package: package, source: source)
        return manifest
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

    private static func checkID(_ id: String, source: BlockSource) throws(BlockInstallError) {
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
        let root = package.standardizedFileURL.path
        let resolved = package.appending(path: path).standardizedFileURL.path
        // `appending(path:)` treats a leading "/" as relative, so an absolute
        // path is refused on its own.
        guard !path.hasPrefix("/"), resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
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
                break
            case .choice:
                if setting.options?.isEmpty ?? true { throw .invalidSetting(setting.key) }
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
