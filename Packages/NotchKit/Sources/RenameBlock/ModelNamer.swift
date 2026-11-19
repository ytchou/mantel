import Foundation
import FoundationModels

/// Whether the on-device model can name screenshots, and if not, why.
enum ModelStatus: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable

    var isAvailable: Bool { self == .available }

    /// One plain sentence for the settings pane.
    var explanation: String {
        switch self {
        case .available:
            "The on-device model is ready. Names describe what the screenshot shows."
        case .deviceNotEligible:
            "This Mac cannot run Apple Intelligence, so screenshots get simple dated names."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off. Turn it on in System Settings for descriptive names."
        case .modelNotReady:
            "The on-device model is still downloading or getting ready. Simple dated names are used until then."
        case .unavailable:
            "The on-device model is not available, so screenshots get simple dated names."
        }
    }
}

/// What the namer gets for one screenshot.
struct NamingRequest: Sendable, Equatable {
    /// Recognised lines, top to bottom.
    var lines: [String]
    var appName: String?
    var length: NameLength
    var language: NameLanguage
}

/// Suggests descriptive words for a screenshot.
protocol ScreenshotNaming: Sendable {
    var status: ModelStatus { get }
    /// Words for the name, before cleaning. May be slow; honours cancellation.
    func suggestName(_ request: NamingRequest) async throws -> String
}

// Guided generation: one @Generable type per length, so the word count is a
// schema constraint. The model still packs several words into one element
// (`spikes/FINDINGS.md`, table C), so `NameCleaner` cuts the result again.

protocol NameWords { var words: [String] { get } }

@Generable
struct ShortName: NameWords {
    @Guide(description: "2 to 4 lowercase words that describe what the screenshot shows, most specific first. No dates, no file extension.", .count(2...4))
    var words: [String]
}

@Generable
struct StandardName: NameWords {
    @Guide(description: "4 to 6 lowercase words that describe what the screenshot shows, most specific first. No dates, no file extension.", .count(4...6))
    var words: [String]
}

@Generable
struct LongName: NameWords {
    @Guide(description: "6 to 9 lowercase words that describe what the screenshot shows, most specific first. No dates, no file extension.", .count(6...9))
    var words: [String]
}

struct ModelNamerError: Error {
    let reason: String
}

/// Names a screenshot with Apple's on-device model (FoundationModels).
/// The API use follows the naming spike (`spikes/screenshot-naming/Sources/NameSpike/Namer.swift`).
struct ModelNamer: ScreenshotNaming {
    /// Characters of recognised text sent to the model. The SDK does not expose
    /// the context size (Apple documents 4096 tokens, not verified); CJK text can
    /// cost a token or more per character, so the text is capped well below.
    static let textLimit = 3000
    /// Used once if the model reports that the context window was exceeded.
    static let retryTextLimit = 1000

    var status: ModelStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unavailable
            }
        }
    }

    func suggestName(_ request: NamingRequest) async throws -> String {
        do {
            return try await generate(request, limit: Self.textLimit)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error else { throw error }
            return try await generate(request, limit: Self.retryTextLimit)
        }
    }

    private func generate(_ request: NamingRequest, limit: Int) async throws -> String {
        let text = Self.truncated(request.lines, limit: limit)
        let words: [String]
        switch request.length {
        case .short: words = try await run(ShortName.self, text: text, request: request)
        case .standard: words = try await run(StandardName.self, text: text, request: request)
        case .long: words = try await run(LongName.self, text: text, request: request)
        }
        return words.joined(separator: " ")
    }

    private func run<T: Generable & NameWords>(_ type: T.Type, text: String, request: NamingRequest) async throws -> [String] {
        let session = LanguageModelSession(instructions: Self.instructions(for: request.language))
        let stream = session.streamResponse(
            to: Self.prompt(text: text, appName: request.appName),
            generating: T.self,
            options: GenerationOptions(sampling: .greedy)
        )
        var last: GeneratedContent?
        for try await snapshot in stream {
            try Task.checkCancellation()
            last = snapshot.rawContent
        }
        guard let content = last else { throw ModelNamerError(reason: "no output") }
        return try T(content).words
    }

    static func instructions(for language: NameLanguage) -> String {
        let languageRule = switch language {
        case .matchContent: "Use the main language of the screenshot text."
        case .english: "Write the words in English, even when the screenshot text is in another language."
        case .traditionalChinese: "Write the words in Traditional Chinese (繁體中文), even when the screenshot text is in another language."
        }
        return """
        You name screenshot files. You get the text that OCR read from one screenshot. \
        Reply with words that describe what the screenshot shows (the app, document, error or topic), \
        not a copy of the text. Use lowercase. Never include dates, times, file extensions or the word "screenshot". \
        \(languageRule)
        """
    }

    static func prompt(text: String, appName: String?) -> String {
        var prompt = ""
        if let appName, !appName.isEmpty {
            prompt += "The screenshot was taken while \(appName) was the frontmost app.\n"
        }
        prompt += """
        OCR text from the screenshot (top to bottom, may be truncated):
        \"\"\"
        \(text)
        \"\"\"
        Give a short descriptive name for the file.
        """
        return prompt
    }

    /// Whole lines, top to bottom, up to `limit` characters.
    static func truncated(_ lines: [String], limit: Int) -> String {
        var out: [String] = []
        var used = 0
        for line in lines {
            let cost = line.count + 1
            if used + cost > limit {
                let room = limit - used
                if room > 20 { out.append(String(line.prefix(room))) }
                break
            }
            out.append(line)
            used += cost
        }
        return out.joined(separator: "\n")
    }
}
