import Foundation
import NaturalLanguage

private let stopWords: Set<String> = [
    "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from",
    "is", "are", "was", "were", "be", "been", "this", "that", "these", "those", "it", "its", "as",
    "your", "you", "we", "our", "my", "me", "i", "he", "she", "they", "them", "his", "her",
    "not", "no", "yes", "ok", "cancel", "close", "done", "please", "could", "can", "will", "would",
    "has", "have", "had", "do", "does", "did", "so", "if", "then", "than", "there", "here",
    "screenshot", "am", "pm",
    "的", "了", "和", "與", "及", "或", "是", "在", "有", "也", "就", "都", "而", "被", "把", "請", "您", "你", "我",
]

/// Names a screenshot with no language model: the most prominent OCR lines near the top
/// (score = text height in px x top bias), tokenised with NLTokenizer (handles Chinese
/// segmentation), stop words and pure numbers removed, optional app name prefixed.
func fallbackName(ocr: OCRResult, app: String?, maxWords: Int = 6) -> [String: Any] {
    let t0 = nowNs()
    let topHalf = ocr.lines.filter { $0.box.maxY >= 0.5 }
    let pool = topHalf.isEmpty ? ocr.lines : topHalf
    let ranked = pool.sorted { a, b in
        a.heightPx * (0.5 + Double(a.box.maxY)) > b.heightPx * (0.5 + Double(b.box.maxY))
    }
    let picked = Array(ranked.prefix(2))

    var tokens: [String] = []
    if let app, !app.isEmpty { tokens.append(contentsOf: app.lowercased().split(separator: " ").map(String.init)) }
    let tokenizer = NLTokenizer(unit: .word)
    for line in picked {
        tokenizer.string = line.text
        tokenizer.enumerateTokens(in: line.text.startIndex..<line.text.endIndex) { range, _ in
            let w = line.text[range].lowercased()
            if stopWords.contains(w) { return true }
            if w.allSatisfy({ $0.isNumber || $0.isPunctuation }) { return true } // dates, ids, times
            if w.count == 1, w.first?.isASCII == true { return true }
            if !tokens.contains(w) { tokens.append(w) }
            return true
        }
    }
    let words = Array(tokens.prefix(maxWords))
    var name = sanitizeFileName(words.joined(separator: " "))
    if name.isEmpty { name = "screenshot" }
    return [
        "name": name,
        "pickedLines": picked.map(\.text),
        "pickedHeightsPx": picked.map { round1($0.heightPx) },
        "app": app as Any,
        "fallbackMs": ms(since: t0),
    ]
}
