import Foundation

/// One line per event to stdout: `<ISO8601 wall clock> +<seconds since launch> [TAG] message`.
/// The monotonic offset makes it easy to compare the latency of the two drag signals.
enum Log {
    static let launch = Date()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func line(_ tag: String, _ message: String) {
        let now = Date()
        let offset = String(format: "%.3f", now.timeIntervalSince(launch))
        print("\(formatter.string(from: now)) +\(offset)s [\(tag)] \(message)")
        fflush(stdout)
    }
}
