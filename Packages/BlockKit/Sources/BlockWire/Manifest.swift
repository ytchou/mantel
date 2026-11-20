import Foundation

/// The `manifest.json` at the top of a `<Name>.topblock` folder.
///
/// Decoding checks the shape only: required fields are present and have the
/// right type. The app checks the meaning (id rules, contract range,
/// executable path, event names) when it installs or launches the block.
public struct Manifest: Codable, Hashable, Sendable {
    /// Lowercase letters, digits and dashes. Also the prefix of the block's
    /// settings keys.
    public var id: String
    public var name: String
    public var version: String
    /// The protocol version the block speaks.
    public var contract: Int
    /// Path of the executable, relative to the package folder.
    public var executable: String
    public var summary: String
    /// SF Symbol name for the block's icon.
    public var symbol: String
    /// What makes the block show, in a few words.
    public var trigger: String
    /// Display-only text.
    public var permissions: [String]
    /// Event names, as in `WireEvent`. Kept as text so the app can name an
    /// unknown event in its message.
    public var events: [String]
    public var settings: [SettingSpec]

    public init(
        id: String,
        name: String,
        version: String,
        contract: Int = Contract.current,
        executable: String,
        summary: String = "",
        symbol: String = "",
        trigger: String = "",
        permissions: [String] = [],
        events: [String] = [],
        settings: [SettingSpec] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.contract = contract
        self.executable = executable
        self.summary = summary
        self.symbol = symbol
        self.trigger = trigger
        self.permissions = permissions
        self.events = events
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, contract, executable, summary, symbol, trigger, permissions, events, settings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        contract = try c.decode(Int.self, forKey: .contract)
        executable = try c.decode(String.self, forKey: .executable)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        events = try c.decodeIfPresent([String].self, forKey: .events) ?? []
        settings = try c.decodeIfPresent([SettingSpec].self, forKey: .settings) ?? []
    }

    /// Decodes `manifest.json` bytes. Every failure names the field.
    public static func decode(_ data: Data) throws(ManifestError) -> Manifest {
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw .missingField(path(context.codingPath + [key]))
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            throw .invalidField(path(context.codingPath))
        } catch let DecodingError.dataCorrupted(context) where !context.codingPath.isEmpty {
            throw .invalidField(path(context.codingPath))
        } catch {
            throw .notJSON
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            .joined(separator: ".")
            .replacingOccurrences(of: ".[", with: "[")
    }
}

public enum ManifestError: Error, Equatable, Sendable {
    /// A required field is missing. The value is its path, such as `id` or `settings[0].key`.
    case missingField(String)
    /// A field has the wrong type or value.
    case invalidField(String)
    /// The bytes are not a JSON object.
    case notJSON
}

/// One setting a block declares. The app draws it, stores it as
/// `<block id>.<key>` and sends its value to the block.
public struct SettingSpec: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// On or off. Value: a bool.
        case toggle
        /// One of `options`. Value: the option's `value`.
        case choice
        /// Text shown under the settings, with no value.
        case note
    }

    public struct Option: Codable, Hashable, Sendable {
        public var value: String
        public var title: String
        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    public var key: String
    public var type: Kind
    public var title: String
    public var `default`: SettingValue?
    public var options: [Option]?

    public init(key: String, type: Kind, title: String, default: SettingValue? = nil, options: [Option]? = nil) {
        self.key = key
        self.type = type
        self.title = title
        self.default = `default`
        self.options = options
    }
}
