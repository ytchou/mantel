import Foundation
import FoundationModels

// Guided generation: one @Generable struct per length so the word count is a schema
// constraint (GenerationGuide.count(ClosedRange<Int>)), not just a prompt request.

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
struct DetailedName: NameWords {
    @Guide(description: "6 to 9 lowercase words that describe what the screenshot shows, most specific first. No dates, no file extension.", .count(6...9))
    var words: [String]
}

/// Characters of OCR text sent to the model. The context window size is NOT exposed by the
/// macOS 26.2 SDK interface (no contextSize/token-count symbol). Apple documents 4096 tokens
/// for the system model (not verified here). CJK text can cost about one token or more per
/// character, so 1200 chars leaves room for instructions, the schema and the answer.
let ocrCharLimit = 1200

let namingInstructions = """
You name screenshot files. You get the text that OCR read from one screenshot. \
Reply with words that describe what the screenshot shows (the app, document, error or topic), \
not a copy of the text. Use lowercase. Never include dates, times, file extensions or the word "screenshot". \
Use the main language of the screenshot text.
"""

func modelAvailability() -> [String: Any] {
    let model = SystemLanguageModel.default
    var r: [String: Any] = [:]
    switch model.availability {
    case .available:
        r["available"] = true
    case .unavailable(let reason):
        r["available"] = false
        r["reason"] = String(describing: reason)
    }
    r["supportedLanguages"] = model.supportedLanguages.map { $0.minimalIdentifier }.sorted()
    r["supportsCurrentLocale"] = model.supportsLocale()
    r["supportsZhHantTW"] = model.supportsLocale(Locale(identifier: "zh-Hant-TW"))
    return r
}

func truncatedOCRText(_ lines: [String], limit: Int) -> (text: String, truncated: Bool) {
    var out: [String] = []
    var used = 0
    for line in lines {
        let cost = line.count + 1
        if used + cost > limit {
            let room = limit - used
            if room > 20 { out.append(String(line.prefix(room))) }
            return (out.joined(separator: "\n"), true)
        }
        out.append(line)
        used += cost
    }
    return (out.joined(separator: "\n"), false)
}

struct GenResult {
    let words: [String]
    let raw: String
    let sessionMs: Double
    let firstSnapshotMs: Double?
    let generateMs: Double
}

func generate<T: Generable & NameWords>(_ type: T.Type, text: String, length: NameLength) async throws -> GenResult {
    let t0 = nowNs()
    let session = LanguageModelSession(instructions: namingInstructions)
    let sessionMs = ms(since: t0)

    let prompt = """
    OCR text from the screenshot (top to bottom, may be truncated):
    \"\"\"
    \(text)
    \"\"\"
    Give \(length.range.lowerBound) to \(length.range.upperBound) words for the file name.
    """

    let t1 = nowNs()
    var first: Double?
    var last: GeneratedContent?
    let stream = session.streamResponse(to: prompt, generating: T.self, options: GenerationOptions(sampling: .greedy))
    for try await snapshot in stream {
        if first == nil { first = ms(since: t1) }
        last = snapshot.rawContent
    }
    let generateMs = ms(since: t1)
    guard let content = last else { throw SpikeError("model stream produced no snapshot") }
    let value = try T(content)
    return GenResult(words: value.words, raw: content.jsonString, sessionMs: sessionMs,
                     firstSnapshotMs: first, generateMs: generateMs)
}

/// Runs the model on OCR lines. Returns a JSON-ready dictionary; never throws.
func runNamer(ocrLines: [String], length: NameLength) async -> [String: Any] {
    let total = nowNs()
    var r: [String: Any] = ["length": length.rawValue, "wordRange": [length.range.lowerBound, length.range.upperBound],
                            "guidedGeneration": true, "ocrCharLimit": ocrCharLimit]
    let avail = modelAvailability()
    r["model"] = avail
    guard avail["available"] as? Bool == true else {
        r["ok"] = false
        r["error"] = "model unavailable: \(avail["reason"] ?? "unknown")"
        r["totalMs"] = ms(since: total)
        return r
    }
    var limit = ocrCharLimit
    for attempt in 1...2 {
        let (text, truncated) = truncatedOCRText(ocrLines, limit: limit)
        r["ocrCharsSent"] = text.count
        r["ocrTruncated"] = truncated
        do {
            let g: GenResult
            switch length {
            case .short: g = try await generate(ShortName.self, text: text, length: length)
            case .standard: g = try await generate(StandardName.self, text: text, length: length)
            case .detailed: g = try await generate(DetailedName.self, text: text, length: length)
            }
            let name = sanitizeFileName(g.words.joined(separator: " "))
            r["ok"] = !name.isEmpty
            r["rawOutput"] = g.raw
            r["words"] = g.words
            r["name"] = name
            r["wordCount"] = wordCount(name)
            r["wordCountInRange"] = length.range.contains(wordCount(name))
            r["sessionCreateMs"] = g.sessionMs
            r["firstSnapshotMs"] = g.firstSnapshotMs as Any
            r["generateMs"] = g.generateMs
            r["totalMs"] = ms(since: total)
            return r
        } catch let e as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = e, attempt == 1 {
                limit /= 3
                r["retriedAfterContextOverflow"] = true
                r["ocrCharLimitAfterRetry"] = limit
                continue
            }
            r["ok"] = false
            r["error"] = "GenerationError: \(e)"
        } catch {
            r["ok"] = false
            r["error"] = "\(error)"
        }
        break
    }
    r["totalMs"] = ms(since: total)
    return r
}

func printNamer(_ r: [String: Any]) {
    let model = r["model"] as? [String: Any] ?? [:]
    if model["available"] as? Bool == true {
        print("Model: available (supports zh-Hant-TW: \(model["supportsZhHantTW"] ?? "?"))")
    } else {
        print("Model: UNAVAILABLE, reason: \(model["reason"] ?? "unknown")")
    }
    print("Length: \(r["length"] ?? "") \(r["wordRange"] ?? ""), OCR chars sent: \(r["ocrCharsSent"] ?? 0) (limit \(ocrCharLimit), truncated: \(r["ocrTruncated"] ?? false))")
    if let raw = r["rawOutput"] { print("Raw model output: \(raw)") }
    if let name = r["name"] { print("Sanitised name: \(name)  (words: \(r["wordCount"] ?? 0), in range: \(r["wordCountInRange"] ?? false))") }
    if let e = r["error"] { print("Error: \(e)") }
    print("Timings: session create \(r["sessionCreateMs"] ?? "-") ms, first snapshot \(r["firstSnapshotMs"] ?? "-") ms, generate \(r["generateMs"] ?? "-") ms, model total \(r["totalMs"] ?? "-") ms")
}
