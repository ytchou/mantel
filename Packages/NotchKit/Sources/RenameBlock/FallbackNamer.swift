import CoreGraphics
import Foundation
import NaturalLanguage

/// One line of text read from a screenshot.
struct RecognizedLine: Sendable, Equatable {
    let text: String
    /// Vision's normalised box: 0...1, origin at the bottom left.
    let box: CGRect
}

/// The words to name a screenshot from, before cleaning.
struct NameDraft: Sendable, Equatable {
    var base: String
    /// Date and time, when there is nothing better (see `NameCleaner.fileName`).
    var stamp: String?
}

/// Names a screenshot without the language model. Pure.
///
/// Content names from raw text are poor on busy screens
/// (`spikes/FINDINGS.md`, table C), so this keeps a tidy dated name:
/// "Screenshot", the app name when known, and up to three words of the
/// biggest text near the top when it clearly looks like a title. Without a
/// title it uses the date and time instead.
enum FallbackNamer {
    static let titleWordLimit = 3

    static func draft(lines: [RecognizedLine], appName: String?, date: Date, timeZone: TimeZone = .current) -> NameDraft {
        var parts = ["Screenshot"]
        if let appName, !appName.isEmpty { parts.append(appName) }
        let title = titleWords(in: lines)
        parts.append(contentsOf: title)
        let base = parts.joined(separator: " ")
        return NameDraft(base: base, stamp: title.isEmpty ? NameCleaner.stampString(date, timeZone: timeZone) : nil)
    }

    /// Up to `limit` meaningful words of the line that looks like a title,
    /// or none when no line clearly stands out.
    static func titleWords(in lines: [RecognizedLine], limit: Int = titleWordLimit) -> [String] {
        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return [] }
        let topHalf = usable.filter { $0.box.maxY >= 0.5 }
        let pool = topHalf.isEmpty ? usable : topHalf
        // Bigger text scores higher; text nearer the top gets up to 1.5x.
        func score(_ line: RecognizedLine) -> Double {
            Double(line.box.height) * (0.5 + Double(line.box.maxY))
        }
        guard let best = pool.max(by: { score($0) < score($1) }) else { return [] }

        let heights = usable.map { Double($0.box.height) }.sorted()
        let median = heights[heights.count / 2]
        let standsOut = usable.count <= 2 || Double(best.box.height) >= median * 1.3
        guard standsOut, (2...80).contains(best.text.count) else { return [] }
        return Array(words(in: best.text).prefix(limit))
    }

    /// Meaningful words of `text`, in order, lower-cased, without repeats.
    /// `NLTokenizer` splits Chinese into words rather than characters; it is
    /// told the language when one is detected. Stop words, numbers (dates,
    /// times, ids) and one-character tokens are dropped.
    static func words(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
            tokenizer.setLanguage(language)
        }
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range].lowercased()
            guard word.count > 1,
                  !stopWords.contains(word),
                  !word.allSatisfy({ $0.isNumber || $0.isPunctuation || $0.isSymbol }),
                  !out.contains(word) else { return true }
            out.append(word)
            return true
        }
        return out
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from",
        "is", "are", "was", "were", "be", "been", "this", "that", "these", "those", "it", "its", "as",
        "your", "you", "we", "our", "my", "me", "i", "he", "she", "they", "them", "his", "her",
        "not", "no", "yes", "ok", "cancel", "close", "done", "please", "could", "can", "will", "would",
        "has", "have", "had", "do", "does", "did", "so", "if", "then", "than", "there", "here",
        "screenshot", "am", "pm",
        "的", "了", "和", "與", "及", "或", "是", "在", "有", "也", "就", "都", "而", "被", "把", "請", "您", "你", "我",
    ]
}
