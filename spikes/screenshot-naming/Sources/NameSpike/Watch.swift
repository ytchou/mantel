import Foundation

let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "pdf"]
let screenCaptureXattr = "com.apple.metadata:kMDItemIsScreenCapture"

/// Reads `defaults read com.apple.screencapture location`; falls back to ~/Desktop.
func screenshotFolder() -> (url: URL, source: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = ["read", "com.apple.screencapture", "location"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    if (try? p.run()) != nil {
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus == 0, !s.isEmpty {
            let path = (s as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return (URL(fileURLWithPath: path), "defaults")
            }
        }
    }
    return (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"), "default ~/Desktop")
}

/// The xattr is a binary plist holding a boolean (or number). nil = attribute absent.
func readScreenCaptureFlag(_ path: String) -> Bool? {
    guard let data = readXattr(path, screenCaptureXattr) else { return nil }
    let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    switch obj {
    case let b as Bool: return b
    case let n as NSNumber: return n.boolValue
    case let s as String: return s == "1" || s.lowercased() == "true"
    default: return nil
    }
}

final class ScreenshotWatcher {
    let folder: URL
    let seconds: Double
    let startedAt = Date()

    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var reported = Set<String>()
    private var dotFiles: [[String: Any]] = []
    private var knownNames = Set<String>()
    private var initialQueryPaths = Set<String>()

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var source: DispatchSourceFileSystemObject?
    private let fsQueue = DispatchQueue(label: "namespike.fs")
    private var queryStarted = false
    private var sourceStarted = false

    init(folder: URL, seconds: Double) {
        self.folder = folder
        self.seconds = seconds
    }

    func run() -> [String: Any] {
        startQuery()
        startDispatchSource()
        print("Watching \(folder.path) for \(Int(seconds)) s. Take a screenshot now (Cmd-Shift-3 / Cmd-Shift-4).")
        // NSMetadataQuery delivers on the main run loop; the timer keeps run(until:) from returning early.
        let keepAlive = Timer(timeInterval: 0.5, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        keepAlive.invalidate()
        query.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        source?.cancel()
        fsQueue.sync {} // drain pending xattr checks that already ran

        lock.lock(); defer { lock.unlock() }
        var byPath: [String: [String: Any]] = [:]
        for e in events {
            guard let path = e["path"] as? String, let method = e["method"] as? String else { continue }
            var entry = byPath[path] ?? ["path": path, "methods": [String]()]
            var methods = entry["methods"] as? [String] ?? []
            methods.append(method)
            entry["methods"] = methods
            entry["\(method)LatencyMs"] = e["latencyMs"]
            if entry["firstMethod"] == nil { entry["firstMethod"] = method }
            byPath[path] = entry
        }
        print("--- summary ---")
        if byPath.isEmpty { print("No new screenshots detected.") }
        for (_, s) in byPath.sorted(by: { $0.key < $1.key }) {
            print("\(s["path"] ?? ""): fired \(s["methods"] ?? []), first: \(s["firstMethod"] ?? "-"), metadataQuery \(s["metadataQueryLatencyMs"] ?? "-") ms, dispatchSource \(s["dispatchSourceLatencyMs"] ?? "-") ms")
        }
        return [
            "command": "watch",
            "folder": folder.path,
            "seconds": seconds,
            "metadataQueryStarted": queryStarted,
            "metadataQueryBatchingInterval": query.notificationBatchingInterval,
            "dispatchSourceStarted": sourceStarted,
            "events": events,
            "perFile": byPath.sorted(by: { $0.key < $1.key }).map { $0.value },
            "tempDotFiles": dotFiles,
        ]
    }

    // MARK: report

    private func report(path: String, method: String, extra: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        let key = method + "|" + path
        guard !reported.contains(key) else { return }
        reported.insert(key)
        let detected = Date()
        let created = fileDates(path).created
        let latency = created.map { round1(detected.timeIntervalSince($0) * 1000) }
        var e: [String: Any] = [
            "path": path, "method": method, "detectedAt": detected,
            "createdAt": created as Any, "latencyMs": latency as Any,
            "sinceWatchStartMs": round1(detected.timeIntervalSince(startedAt) * 1000),
        ]
        e.merge(extra) { _, new in new }
        events.append(e)
        let extraText = extra.isEmpty ? "" : " " + extra.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        print("[\(method)] \(path)  latency=\(latency.map { "\($0)" } ?? "?") ms after creation date\(extraText)")
    }

    // MARK: a. NSMetadataQuery

    private func startQuery() {
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        var scopes: [Any] = [NSMetadataQueryUserHomeScope]
        if !folder.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path) { scopes.append(folder) }
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.05

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [unowned self] _ in
            self.query.disableUpdates()
            var paths = Set<String>()
            for i in 0..<self.query.resultCount {
                if let item = self.query.result(at: i) as? NSMetadataItem,
                   let p = item.value(forAttribute: NSMetadataItemPathKey) as? String { paths.insert(p) }
            }
            self.query.enableUpdates()
            self.lock.lock(); self.initialQueryPaths = paths; self.lock.unlock()
            print("[metadataQuery] initial gather done: \(paths.count) existing screen captures (ignored)")
        })
        observers.append(nc.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [unowned self] note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let changed = note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? []
            for (kind, items) in [("added", added), ("changed", changed)] {
                for item in items {
                    guard let p = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                    self.lock.lock(); let old = self.initialQueryPaths.contains(p); self.lock.unlock()
                    if old { continue }
                    self.report(path: p, method: "metadataQuery", extra: ["updateKind": kind])
                }
            }
        })
        queryStarted = query.start()
        if !queryStarted { print("[metadataQuery] start() returned false") }
    }

    // MARK: b. DispatchSource on the folder

    private func startDispatchSource() {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            print("[dispatchSource] cannot open \(folder.path): errno \(errno)")
            return
        }
        knownNames = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: fsQueue)
        src.setEventHandler { [unowned self] in self.scanFolder() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        sourceStarted = true
    }

    /// Runs on fsQueue.
    private func scanFolder() {
        let now = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let added = now.subtracting(knownNames)
        let removed = knownNames.subtracting(now)
        knownNames = now
        for name in removed where name.hasPrefix(".") {
            print("[dispatchSource] temp dot-file gone (renamed to final name): \(name)")
        }
        for name in added.sorted() {
            let path = folder.appendingPathComponent(name).path
            if name.hasPrefix(".") {
                // macOS writes ".Screenshot ....png" first, then renames it to the final name.
                lock.lock()
                dotFiles.append(["name": name, "seenAt": Date(), "sinceWatchStartMs": round1(Date().timeIntervalSince(startedAt) * 1000)])
                lock.unlock()
                print("[dispatchSource] temp dot-file appeared (ignored): \(name)")
                continue
            }
            guard imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            checkXattr(path: path, seenAt: Date(), attempt: 0)
        }
    }

    /// The screen-capture xattr can land slightly after the file; poll every 25 ms for up to 1 s.
    private func checkXattr(path: String, seenAt: Date, attempt: Int) {
        let created = fileDates(path).created
        let seenLatency = created.map { round1(seenAt.timeIntervalSince($0) * 1000) }
        if let flag = readScreenCaptureFlag(path) {
            if flag {
                report(path: path, method: "dispatchSource", extra: [
                    "fileSeenLatencyMs": seenLatency as Any,
                    "xattrWaitMs": round1(Date().timeIntervalSince(seenAt) * 1000),
                ])
            } else {
                print("[dispatchSource] new image but kMDItemIsScreenCapture is false: \(path)")
            }
        } else if attempt < 40 {
            fsQueue.asyncAfter(deadline: .now() + 0.025) { [unowned self] in
                self.checkXattr(path: path, seenAt: seenAt, attempt: attempt + 1)
            }
        } else {
            print("[dispatchSource] new image without \(screenCaptureXattr) after 1 s (not a screenshot?): \(path)")
        }
    }
}
