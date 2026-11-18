import Foundation
import Observation

/// How many words a name keeps. The model ignores requested lengths
/// (`spikes/FINDINGS.md`, table C), so the cut happens in `NameCleaner`.
enum NameLength: String, CaseIterable, Sendable {
    case short
    case standard
    case long

    var wordLimit: Int {
        switch self {
        case .short: 3
        case .standard: 5
        case .long: 8
        }
    }

    var title: String {
        switch self {
        case .short: "Short"
        case .standard: "Standard"
        case .long: "Long"
        }
    }
}

/// Language of generated names. Chinese screenshots get English names unless
/// the model is told otherwise (`spikes/FINDINGS.md`, table C).
enum NameLanguage: String, CaseIterable, Sendable {
    case matchContent
    case english
    case traditionalChinese

    var title: String {
        switch self {
        case .matchContent: "Match content"
        case .english: "English"
        case .traditionalChinese: "Traditional Chinese"
        }
    }
}

/// The settings one naming job uses, copied when the job starts.
struct NamingOptions: Sendable, Equatable {
    var length: NameLength = .standard
    var language: NameLanguage = .matchContent
    var datePrefix = false
    var appNameSuffix = false
}

/// The block's settings, stored in `UserDefaults` under keys prefixed `rename.`.
@MainActor
@Observable
final class RenameSettings {
    enum Key {
        static let length = "rename.nameLength"
        static let language = "rename.nameLanguage"
        static let datePrefix = "rename.datePrefix"
        static let appNameSuffix = "rename.appNameSuffix"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var length: NameLength {
        didSet { defaults.set(length.rawValue, forKey: Key.length) }
    }

    var language: NameLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    var datePrefix: Bool {
        didSet { defaults.set(datePrefix, forKey: Key.datePrefix) }
    }

    var appNameSuffix: Bool {
        didSet { defaults.set(appNameSuffix, forKey: Key.appNameSuffix) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        length = defaults.string(forKey: Key.length).flatMap(NameLength.init(rawValue:)) ?? .standard
        language = defaults.string(forKey: Key.language).flatMap(NameLanguage.init(rawValue:)) ?? .matchContent
        datePrefix = defaults.bool(forKey: Key.datePrefix)
        appNameSuffix = defaults.bool(forKey: Key.appNameSuffix)
    }

    var options: NamingOptions {
        NamingOptions(length: length, language: language, datePrefix: datePrefix, appNameSuffix: appNameSuffix)
    }
}
