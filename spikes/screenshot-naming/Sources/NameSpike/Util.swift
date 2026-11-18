import Foundation

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Timing

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

/// Milliseconds since `t` (from `nowNs()`), rounded to 0.1 ms.
func ms(since t: UInt64) -> Double {
    round1(Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000)
}

// MARK: - JSON output

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

func jsonSafe(_ v: Any) -> Any {
    switch v {
    case let d as [String: Any]: return d.mapValues(jsonSafe)
    case let a as [Any]: return a.map(jsonSafe)
    case let date as Date: return iso(date)
    case let b as Bool: return b
    case let i as Int: return i
    case let x as Double: return x.isFinite ? x : NSNull()
    case let s as String: return s
    case is NSNull: return v
    default:
        let m = Mirror(reflecting: v)
        if m.displayStyle == .optional {
            if let c = m.children.first { return jsonSafe(c.value) }
            return NSNull()
        }
        return String(describing: v)
    }
}

/// Prints one JSON object on a single line (the machine-readable last line of every subcommand).
func printJSON(_ obj: [String: Any]) {
    let clean = jsonSafe(obj)
    if let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    } else {
        print("{\"error\":\"json encoding failed\"}")
    }
}

// MARK: - File name sanitiser (shared by name, fallback, rename)

/// Letters and digits are kept (ASCII lowercased, CJK and other scripts kept as-is).
/// Everything else (whitespace, path separators, `:`, punctuation, emoji, control chars)
/// collapses to a single hyphen. Capped at `maxLength` characters, cut at a hyphen when possible.
func sanitizeFileName(_ input: String, maxLength: Int = 60) -> String {
    var out = ""
    var lastWasHyphen = true // suppresses a leading hyphen
    for ch in input.precomposedStringWithCanonicalMapping {
        if ch.isLetter || ch.isNumber {
            out += ch.isASCII ? ch.lowercased() : String(ch)
            lastWasHyphen = false
        } else if !lastWasHyphen {
            out += "-"
            lastWasHyphen = true
        }
    }
    while out.hasSuffix("-") { out.removeLast() }
    if out.count > maxLength {
        var cut = String(out.prefix(maxLength))
        if let r = cut.range(of: "-", options: .backwards), cut.distance(from: cut.startIndex, to: r.lowerBound) >= maxLength / 2 {
            cut = String(cut[..<r.lowerBound])
        }
        while cut.hasSuffix("-") { cut.removeLast() }
        out = cut
    }
    return out
}

func wordCount(_ slug: String) -> Int {
    slug.split(separator: "-").count
}

enum NameLength: String, CaseIterable {
    case short, standard, detailed

    var range: ClosedRange<Int> {
        switch self {
        case .short: return 2...4
        case .standard: return 4...6
        case .detailed: return 6...9
        }
    }
}

// MARK: - Extended attributes

func readXattr(_ path: String, _ name: String) -> Data? {
    let size = getxattr(path, name, nil, 0, 0, 0)
    guard size >= 0 else { return nil }
    var data = Data(count: size)
    let got = data.withUnsafeMutableBytes { buf in
        getxattr(path, name, buf.baseAddress, size, 0, 0)
    }
    guard got >= 0 else { return nil }
    return data.prefix(got)
}

@discardableResult
func writeXattr(_ path: String, _ name: String, _ value: Data) -> Bool {
    value.withUnsafeBytes { buf in
        setxattr(path, name, buf.baseAddress, value.count, 0, 0) == 0
    }
}

@discardableResult
func removeXattr(_ path: String, _ name: String) -> Bool {
    removexattr(path, name, 0) == 0
}

func fileDates(_ path: String) -> (created: Date?, modified: Date?) {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return (attrs?[.creationDate] as? Date, attrs?[.modificationDate] as? Date)
}
