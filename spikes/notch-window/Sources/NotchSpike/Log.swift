import AppKit

/// One line per event: wall clock + seconds since launch + event + detail.
let spikeStart = Date()

private let tsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ event: String, _ detail: String = "") {
    let now = Date()
    let elapsed = String(format: "%.3f", now.timeIntervalSince(spikeStart))
    let suffix = detail.isEmpty ? "" : " " + detail
    print("[\(tsFormatter.string(from: now)) +\(elapsed)s] \(event)\(suffix)")
    fflush(stdout)
}

func fmt(_ r: CGRect) -> String {
    String(format: "(x:%.1f y:%.1f w:%.1f h:%.1f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
}

func fmt(_ p: CGPoint) -> String {
    String(format: "(%.1f, %.1f)", p.x, p.y)
}

func rectDict(_ r: CGRect) -> [String: Double] {
    ["x": Double(r.origin.x), "y": Double(r.origin.y), "w": Double(r.size.width), "h": Double(r.size.height)]
}

func describeApp(_ app: NSRunningApplication?) -> String {
    guard let app else { return "nil" }
    return "\(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "no-bundle-id")] pid=\(app.processIdentifier)"
}
