import AppKit
import NotchCore
import Observation
import os
import SwiftUI

/// What the rename block's views show. The views observe it, so updates need
/// no new `present` call.
@MainActor
@Observable
final class RenameModel {
    enum Phase: Equatable {
        case idle
        case naming
        case renamed(RecentRename)
        case failed(String)
    }

    var phase: Phase = .idle
    var thumbnail: Thumbnail?
    /// Screenshots waiting behind the current one.
    var waiting = 0
    /// Newest first, at most `RecentsStore.limit`.
    var recents: [RecentRename] = []
    /// A revert from the list that failed.
    var listMessage: String?
    var modelStatus: ModelStatus = .unavailable
}

/// Names new screenshots from their content, on device.
///
/// On `ScreenshotCaptured` it shows "Naming…" in the peek, reads the text with
/// Vision, asks the on-device model for a name (fallback: a tidy dated name),
/// renames the file in place and shows the new name with Undo. Screenshots
/// that arrive together are handled one at a time, in order.
@MainActor
public final class RenameBlock: NotchBlock {
    public let id: BlockID = "rename"
    public let title = "Screenshot Names"
    public let info = BlockInfo(
        summary: "Gives each new screenshot a name that says what is in it.",
        symbol: "camera.viewfinder",
        trigger: "Taking a screenshot",
        permissions: ["Access to the screenshot folder", "Apple Intelligence (optional)"]
    )

    static let peekSize = CGSize(width: 340, height: 36)
    static let expandedSize = CGSize(width: 520, height: 260)
    static let resultDuration: Duration = .seconds(6)
    static let failureDuration: Duration = .seconds(4)

    let model = RenameModel()
    let settings: RenameSettings
    private let pipeline: RenamePipeline
    private let renamer = Renamer()
    private let recentsStore: RecentsStore
    private let frontmostAppName: @MainActor () -> String?
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "rename")

    private var context: (any BlockContext)?
    private var queue: [RenameJob] = []
    private(set) var current: RenameJob?
    private var worker: Task<Void, Never>?
    /// Files this block moved back by undo. The watcher may report them as
    /// new; they must not be renamed again.
    private var undonePaths: Set<String> = []

    public convenience init() {
        self.init(
            reader: VisionTextReader(),
            namer: ModelNamer(),
            defaults: .standard,
            recentsURL: RecentsStore.defaultURL,
            frontmostAppName: RenameBlock.currentFrontmostAppName
        )
    }

    /// For tests: every slow or system-bound part is injected.
    init(
        reader: any TextReading,
        namer: any ScreenshotNaming,
        timeLimit: Duration = .seconds(10),
        defaults: UserDefaults,
        recentsURL: URL,
        frontmostAppName: @escaping @MainActor () -> String? = { nil },
        timeZone: TimeZone = .current
    ) {
        settings = RenameSettings(defaults: defaults)
        pipeline = RenamePipeline(reader: reader, namer: namer, renamer: Renamer(), timeLimit: timeLimit, timeZone: timeZone)
        recentsStore = RecentsStore(url: recentsURL)
        self.frontmostAppName = frontmostAppName
        model.recents = recentsStore.load()
        model.modelStatus = namer.status
    }

    // MARK: NotchBlock

    public func activate(_ context: any BlockContext) {
        self.context = context
        context.subscribe(to: ScreenshotCaptured.self) { [weak self] event in
            self?.captured(event)
        }
    }

    public func deactivate() {
        worker?.cancel()
        worker = nil
        current = nil
        queue.removeAll()
        model.phase = .idle
        model.waiting = 0
        model.thumbnail = nil
        context = nil
    }

    public var actions: [BlockAction] {
        let last = model.recents.first
        let enabled = last.map { !$0.reverted && FileManager.default.fileExists(atPath: $0.renamedURL.path) } ?? false
        return [
            BlockAction(id: "undo-last-rename", title: "Undo Last Rename", isEnabled: enabled) { [weak self] in
                self?.undoLast()
            },
        ]
    }

    public var settingsPane: AnyView? {
        AnyView(RenameSettingsView(settings: settings, model: model) { [weak self] in
            self?.refreshModelStatus()
        })
    }

    // MARK: Queue

    private func captured(_ event: ScreenshotCaptured) {
        let url = event.url.standardizedFileURL
        if undonePaths.remove(url.path) != nil { return }
        guard current?.url != url, !queue.contains(where: { $0.url == url }) else { return }
        queue.append(RenameJob(url: url, createdAt: event.createdAt, appName: frontmostAppName()))
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard current == nil, !queue.isEmpty else {
            model.waiting = queue.count
            return
        }
        let job = queue.removeFirst()
        current = job
        model.waiting = queue.count
        model.thumbnail = nil
        model.phase = .naming
        refreshModelStatus()
        present(duration: nil)

        let pipeline = self.pipeline
        let options = settings.options
        worker = Task { [weak self] in
            let thumbnail = await pipeline.thumbnail(for: job.url)
            if let self, self.current?.id == job.id { self.model.thumbnail = thumbnail }
            let outcome = await pipeline.run(job, options: options)
            self?.finish(job, outcome)
        }
    }

    private func finish(_ job: RenameJob, _ outcome: RenameOutcome) {
        guard current?.id == job.id else { return }
        current = nil
        worker = nil
        let isLast = queue.isEmpty
        switch outcome {
        case let .renamed(from, to, usedFallback):
            let item = RecentRename(
                folderPath: to.deletingLastPathComponent().path,
                newName: to.lastPathComponent,
                originalName: Renamer.originalName(of: to) ?? from.lastPathComponent,
                renamedAt: Date(),
                usedFallback: usedFallback
            )
            model.recents.insert(item, at: 0)
            if model.recents.count > RecentsStore.limit {
                model.recents.removeLast(model.recents.count - RecentsStore.limit)
            }
            saveRecents()
            if isLast {
                model.phase = .renamed(item)
                present(duration: Self.resultDuration)
            }
        case .dropped:
            if isLast {
                model.phase = .idle
                context?.dismiss()
            }
        case let .failed(reason):
            if isLast {
                model.phase = .failed(reason)
                present(duration: Self.failureDuration)
            }
        }
        startNextIfIdle()
    }

    private func present(duration: Duration?) {
        let model = self.model
        let undo: @MainActor () -> Void = { [weak self] in self?.undoShown() }
        let revert: @MainActor (RecentRename) -> Void = { [weak self] item in self?.revert(item) }
        context?.present(Presentation(
            priority: .standard,
            peek: NotchContent(size: Self.peekSize) { RenamePeekView(model: model, undo: undo) },
            expanded: NotchContent(size: Self.expandedSize) { RenameRecentsView(model: model, revert: revert) },
            duration: duration
        ))
    }

    // MARK: Undo

    func undoShown() {
        guard case let .renamed(item) = model.phase else { return }
        revert(item)
    }

    func undoLast() {
        guard let last = model.recents.first else { return }
        revert(last)
    }

    /// Move a renamed file back to its original name.
    func revert(_ item: RecentRename) {
        guard let index = model.recents.firstIndex(where: { $0.id == item.id }), !model.recents[index].reverted else { return }
        var isShown = false
        if case let .renamed(shown) = model.phase, shown.id == item.id { isShown = true }
        do {
            let restored = try renamer.undo(item.renamedURL, originalName: item.originalName)
            undonePaths.insert(restored.standardizedFileURL.path)
            model.recents[index].reverted = true
            model.listMessage = nil
            saveRecents()
            log.info("reverted \(item.newName, privacy: .private) to \(item.originalName, privacy: .private)")
            if isShown {
                model.phase = .idle
                context?.dismiss()
            }
        } catch {
            let message = (error as? RenameError)?.message ?? RenameError.failed("").message
            log.error("revert failed: \(String(describing: error), privacy: .private)")
            if isShown {
                model.phase = .failed(message)
                present(duration: Self.failureDuration)
            } else {
                model.listMessage = message
            }
        }
    }

    // MARK: Helpers

    private func refreshModelStatus() {
        model.modelStatus = pipeline.namer.status
    }

    private func saveRecents() {
        do {
            try recentsStore.save(model.recents)
        } catch {
            log.error("saving recent renames failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// The app in front when the screenshot arrived, unless it is this app.
    static func currentFrontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app.localizedName
    }
}
