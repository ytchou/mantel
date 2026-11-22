import Foundation
import NotchCore
import os

/// Watches the screenshot folder and publishes `ScreenshotCaptured` for each
/// new screenshot file.
///
/// Measured in the naming spike (`spikes/FINDINGS.md`, decision 3): a
/// file-system source on the folder sees a new screenshot 20 to 40 ms after it
/// is written, and the screen-capture attribute is already there.
/// `NSMetadataQuery` never fired, so it is not used.
@MainActor
public final class ScreenshotWatcher {
    private let runtime: NotchRuntime
    private(set) var scanner: ScreenshotFolderScanner?
    private let log = Logger(subsystem: "dev.mantel.Mantel", category: "screenshots")

    public init(runtime: NotchRuntime) {
        self.runtime = runtime
    }

    /// Start watching. Reads the screenshot folder setting each time it
    /// starts after a stop; a second `start()` while watching does nothing.
    public func start() {
        guard scanner == nil else { return }
        let folder = ScreenshotFolder.current()
        let runtime = self.runtime
        let log = self.log
        let scanner = ScreenshotFolderScanner(folder: folder, startedAt: Date()) { url, createdAt in
            Task { @MainActor in
                let latency = Int(Date().timeIntervalSince(createdAt) * 1000)
                log.info("screenshot \(url.lastPathComponent, privacy: .private) published \(latency) ms after creation")
                runtime.publish(ScreenshotCaptured(url: url, createdAt: createdAt))
            }
        }
        scanner.start()
        self.scanner = scanner
        log.info("watching screenshot folder \(folder.path, privacy: .private)")
    }

    public func stop() {
        scanner?.stop()
        scanner = nil
    }
}

/// The folder source and its listing. Every mutable property is touched only
/// on `queue`, which is why the type is `@unchecked Sendable`.
final class ScreenshotFolderScanner: @unchecked Sendable {
    let folder: URL
    private let queue = DispatchQueue(label: "dev.mantel.screenshots")
    private let onScreenshot: @Sendable (URL, Date) -> Void
    private var tracker: ScreenshotTracker
    private var source: DispatchSourceFileSystemObject?
    private var isStopped = false
    private let log = Logger(subsystem: "dev.mantel.Mantel", category: "screenshots")

    /// The screen-capture attribute or the file size can lag the file name
    /// slightly. Look again every 50 ms, for up to 2 s.
    private static let retryInterval: DispatchTimeInterval = .milliseconds(50)
    private static let maxAttempts = 40

    init(folder: URL, startedAt: Date, onScreenshot: @escaping @Sendable (URL, Date) -> Void) {
        self.folder = folder
        self.onScreenshot = onScreenshot
        self.tracker = ScreenshotTracker(startedAt: startedAt)
    }

    deinit {
        source?.cancel()
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func stop() {
        queue.async {
            self.isStopped = true
            self.source?.cancel()
            self.source = nil
        }
    }

    private func startOnQueue() {
        guard !isStopped, source == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            let code = errno
            log.error("cannot open screenshot folder \(self.folder.path, privacy: .private): errno \(code)")
            return
        }
        tracker = ScreenshotTracker(startedAt: tracker.startedAt, existing: listing())
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: queue
        )
        source.setEventHandler { [weak self] in self?.scan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func listing() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private func scan() {
        guard !isStopped else { return }
        for name in tracker.added(in: listing()) where ScreenshotCandidate.isCandidateName(name) {
            check(name, attempt: 0)
        }
    }

    private func check(_ name: String, attempt: Int) {
        guard !isStopped else { return }
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        let facts = ScreenshotCandidate.facts(at: url)
        switch ScreenshotCandidate.decide(facts, startedAt: tracker.startedAt) {
        case .publish:
            guard tracker.markPublished(name) else { return }
            onScreenshot(url, facts.createdAt ?? Date())
        case .retry:
            guard attempt < Self.maxAttempts else {
                log.debug("new image is not a confirmed screenshot after 2 s: \(name, privacy: .private)")
                return
            }
            queue.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
                self?.check(name, attempt: attempt + 1)
            }
        case .ignore:
            return
        }
    }
}
