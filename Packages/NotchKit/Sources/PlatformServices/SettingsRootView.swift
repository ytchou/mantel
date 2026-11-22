import AppKit
import NotchCore
import SwiftUI

/// Root of the Settings window: a sidebar with "General" and "Blocks" first,
/// then one entry per registered block, in rank order.
public struct SettingsRootView: View {
    private let runtime: NotchRuntime
    private let settings: BlockSettings
    private let installer: (any BlockInstalling)?
    private let consent: ScreenshotFolderConsent?
    private let example: ExampleOffer?
    @State private var selection: SettingsPane?

    /// - Parameters:
    ///   - installer: installs, updates and removes blocks from the
    ///     Blocks page. Nil hides those buttons.
    ///   - consent: the screenshot folder answer, see `SettingsWindowController`.
    ///   - exampleURL: the example block's package; with an installer, the
    ///     empty Blocks page offers it.
    public init(runtime: NotchRuntime, settings: BlockSettings, installer: (any BlockInstalling)? = nil,
                consent: ScreenshotFolderConsent? = nil, exampleURL: URL? = nil) {
        self.init(runtime: runtime, settings: settings, installer: installer, consent: consent, exampleURL: exampleURL,
                  selection: .general)
    }

    /// Opens on a chosen pane. Internal, for checking a pane without clicking.
    init(runtime: NotchRuntime, settings: BlockSettings, installer: (any BlockInstalling)? = nil,
         consent: ScreenshotFolderConsent? = nil, exampleURL: URL? = nil, selection: SettingsPane) {
        self.runtime = runtime
        self.settings = settings
        self.installer = installer
        self.consent = consent
        example = ExampleOffer(url: exampleURL, installer: installer)
        _selection = State(initialValue: selection)
    }

    public var body: some View {
        // Built here, inside `body`, so a block's health and info are read
        // live: the page redraws when a stand-in's observable state changes.
        let entries = runtime.blocks.map {
            BlockEntry(block: $0, installer: installer, runtime: runtime, consent: consent)
        }
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag(SettingsPane.general)
                Label("Blocks", systemImage: "square.grid.2x2").tag(SettingsPane.blocks)
                let sidebar = BlockEntry.sidebar(entries)
                if !sidebar.isEmpty {
                    Section("Block Settings") {
                        ForEach(sidebar) { entry in
                            Label(entry.title, systemImage: entry.info.symbol).tag(SettingsPane.block(entry.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch selection {
            case .blocks:
                BlocksPane(entries: entries, runtime: runtime, settings: settings, installer: installer, example: example)
            case let .block(id):
                if let block = runtime.blocks.first(where: { $0.id == id }) {
                    BlockPane(block: block, runtime: runtime, settings: settings)
                }
            case .general, nil:
                GeneralPane(runtime: runtime, consent: consent)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        // A removed block's pane is gone; show the Blocks page instead.
        .onChange(of: runtime.blocks.map(\.id)) { _, ids in
            selection = selection?.remaining(in: ids)
        }
    }
}

enum SettingsPane: Hashable {
    case general
    case blocks
    case block(BlockID)

    /// This pane while it still exists among `blocks`; the Blocks page when
    /// it is the pane of a block that is no longer registered.
    func remaining(in blocks: [BlockID]) -> SettingsPane {
        if case let .block(id) = self, !blocks.contains(id) { return .blocks }
        return self
    }
}

struct BlockEntry: Identifiable {
    let id: BlockID
    let title: String
    let info: BlockInfo
    let health: BlockHealth
    /// True for a block the user installed, which can be updated and removed.
    let isRemovable: Bool
    /// False for a block that cannot start whatever the user does, such as an
    /// installed package refused at launch.
    let canTurnOn: Bool
    /// What the block's process used at the last sample, or nil.
    let usage: BlockUsage?
    /// Set while the block waits for the owner's review.
    let review: BlockReview?
    /// Something to know about a block that runs, shown in the warning box.
    let notice: String?
    /// True when an installer can show the sheet that approves a block waiting for review.
    let canReview: Bool
    /// Shown as "~" at the start of a path.
    let home: String

    init(id: BlockID, title: String, info: BlockInfo, health: BlockHealth = .ok, isRemovable: Bool = false,
         canTurnOn: Bool = true, usage: BlockUsage? = nil, review: BlockReview? = nil, notice: String? = nil,
         canReview: Bool = false, home: String = NSHomeDirectory()) {
        self.id = id
        self.title = title
        self.info = info
        self.health = health
        self.isRemovable = isRemovable
        self.canTurnOn = canTurnOn
        self.usage = usage
        self.review = review
        self.notice = notice
        self.canReview = canReview
        self.home = home
    }

    /// Reads the block's state now. Call it inside `body` so changes redraw.
    /// - Parameters:
    ///   - runtime, consent: with both, a turned-on block that listens to
    ///     screenshots while the screenshot folder is refused gets
    ///     `screenshotFolderNotice`, as its source does not run.
    @MainActor
    init(block: any NotchBlock, installer: (any BlockInstalling)?, runtime: NotchRuntime? = nil,
         consent: ScreenshotFolderConsent? = nil, home: String = NSHomeDirectory()) {
        let folderRefused = consent?.isRefused == true
            && runtime?.isSubscribed(block.id, to: ScreenshotCaptured.self) == true
        let notices = [folderRefused ? Self.screenshotFolderNotice : nil, block.notice].compactMap { $0 }
        self.init(id: block.id, title: block.title, info: block.info, health: block.health,
                  isRemovable: installer?.canRemove(block.id) ?? false,
                  canTurnOn: installer?.canTurnOn(block.id) ?? true,
                  usage: block.usage, review: block.review,
                  notice: notices.isEmpty ? nil : notices.joined(separator: "\n"),
                  canReview: installer != nil, home: home)
    }

    /// Shown on a turned-on block that listens to screenshots while macOS
    /// refuses the screenshot folder.
    static let screenshotFolderNotice = "Screenshot folder access is off. Allow it in Settings > General."

    /// The footer of the Blocks page's install section, such as
    /// "Blocks live in ~/Library/Application Support/Mantel/Blocks".
    static func blocksFolderNote(_ folder: URL, home: String = NSHomeDirectory()) -> String {
        "Blocks live in " + abbreviate(folder.path, home: home)
    }

    /// What the Blocks page offers in place of the list when it has no
    /// entry, running, waiting for review or refused; nil while it has any.
    static func emptyActions(_ entries: [BlockEntry], installer: (any BlockInstalling)?,
                             example: ExampleOffer?) -> [EmptyBlocksAction]? {
        guard entries.isEmpty else { return nil }
        return (installer == nil ? [] : [.installBlock]) + (example == nil ? [] : [.installExample])
    }

    /// The entries listed in the sidebar: every block that can run, not
    /// those waiting for review.
    static func sidebar(_ entries: [BlockEntry]) -> [BlockEntry] {
        entries.filter { $0.review == nil }
    }

    /// "New" or "Changed" while the block waits for review, else nil.
    var badge: String? {
        switch review {
        case .new?: "New"
        case .changed?: "Changed"
        case nil: nil
        }
    }

    /// Why the block waits for review, in place of its summary.
    var reviewText: String? {
        switch review {
        case .new?: "Found in the Blocks folder. Review it before it can run."
        case .changed?: "This package changed since you approved it."
        case nil: nil
        }
    }

    /// A "Review…" button, for a block waiting for review.
    var offersReview: Bool { review != nil && canReview }
    /// A block waiting for review has no on/off switch, but a "Review…"
    /// button: it cannot run.
    var hasSwitch: Bool { review == nil }
    /// Nor Move Up and Move Down.
    var hasOrderControls: Bool { review == nil }

    /// The row's title and badge, read as one.
    var accessibilityLabel: String {
        badge.map { "\(title), \($0)" } ?? title
    }

    /// What the process used, such as "38 MB · 0.1% processor", or nil.
    var usageLine: String? {
        guard let usage else { return nil }
        let memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: usage.memoryBytes), countStyle: .memory)
        return "\(memory) · \(String(format: "%.1f", usage.processorFraction * 100))% processor"
    }

    /// Where the block comes from, its version, the trigger, the permissions
    /// and recent restarts on one line, such as
    /// "Built in · Taking a screenshot · Needs: Access to the screenshot folder"
    /// or "Installed from ~/dev/hello-block · 0.2 · Pointer hover · Restarted once".
    /// For a block waiting for review: its package, its version and "Off".
    var detail: String {
        let waiting = review != nil
        // A block waiting for review shows only its package's path.
        let source: String? = switch info.source {
        case .builtIn: waiting ? nil : "Built in"
        case let .installed(from): (waiting ? "" : "Installed from ") + abbreviated(from)
        case let .development(path): (waiting ? "" : "Development · ") + abbreviated(path)
        }
        var parts = [source].compactMap { $0 }
        if let version = info.version, !version.isEmpty { parts.append(version) }
        if waiting { return (parts + ["Off"]).joined(separator: " · ") }
        if !info.trigger.isEmpty { parts.append(info.trigger) }
        if !info.permissions.isEmpty { parts.append("Needs: " + info.permissions.joined(separator: ", ")) }
        if case let .restarting(count) = health {
            parts.append(count == 1 ? "Restarted once" : "Restarted \(count) times")
        }
        return parts.joined(separator: " · ")
    }

    /// Why the app turned the block off, or nil. Nil for a block waiting for
    /// review: `reviewText` says why it does not run.
    var turnedOffReason: String? {
        if review == nil, case let .turnedOff(reason) = health { return reason }
        return nil
    }

    /// A "Turn On" button is shown while the app has turned the block off,
    /// unless turning it on cannot start it.
    var offersTurnOn: Bool { turnedOffReason != nil && canTurnOn }

    /// `path` with the home folder written as "~".
    private func abbreviated(_ path: String) -> String {
        Self.abbreviate(path, home: home)
    }

    private static func abbreviate(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Blocks page

/// A button of the empty Blocks page.
enum EmptyBlocksAction: Equatable {
    case installBlock
    case installExample

    var title: String {
        switch self {
        case .installBlock: "Install Block\u{2026}"
        case .installExample: "Install the Example Block"
        }
    }
}

/// Every registered block with what it does, where it comes from, what
/// starts it, what it needs, and its on/off switch. With an installer, blocks
/// the user installed can be updated and removed, and new ones installed.
private struct BlocksPane: View {
    let entries: [BlockEntry]
    let runtime: NotchRuntime
    let settings: BlockSettings
    let installer: (any BlockInstalling)?
    let example: ExampleOffer?

    /// The package chosen with "Install Block…", "Install the Example Block"
    /// or "Update…", waiting for confirmation.
    @State private var pending: PendingInstall?
    /// A refusal or failure, shown in an alert.
    @State private var failure: Failure?
    /// The block waiting for the user to confirm Remove.
    @State private var removing: BlockEntry?
    @FocusState private var exampleFocused: Bool

    init(entries: [BlockEntry], runtime: NotchRuntime, settings: BlockSettings, installer: (any BlockInstalling)?,
         example: ExampleOffer?) {
        self.entries = entries
        self.runtime = runtime
        self.settings = settings
        self.installer = installer
        self.example = example
    }

    var body: some View {
        Group {
            if let actions = BlockEntry.emptyActions(entries, installer: installer, example: example) {
                empty(actions)
            } else {
                list
            }
        }
        .navigationTitle("Blocks")
        .installReview($pending, failure: $failure, installer: installer)
        .alert(removing.map { "Remove \($0.title)?" } ?? "", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), presenting: removing) { entry in
            Button("Remove", role: .destructive) { remove(entry.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its package, settings and data are deleted.")
        }
    }

    /// No block at all: what a block is, where packages go, and how to add one.
    private func empty(_ actions: [EmptyBlocksAction]) -> some View {
        ContentUnavailableView {
            Label("No Blocks Yet", systemImage: "square.grid.2x2")
        } description: {
            Text("A block adds one thing to your notch. Put a .mantelblock package in ~/Library/Application Support/Mantel/Blocks, or install one here.")
        } actions: {
            HStack {
                ForEach(actions, id: \.self) { action in
                    switch action {
                    case .installBlock:
                        Button(action.title) { choosePackage() }
                    case .installExample:
                        Button(action.title) { chooseExample() }
                            .focused($exampleFocused)
                    }
                }
            }
        }
        .defaultFocus($exampleFocused, true)
    }

    private var list: some View {
        Form {
            Section {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if entry.hasSwitch {
                        row(entry)
                            .accessibilityLabel(entry.accessibilityLabel)
                    } else {
                        reviewRow(entry)
                    }
                    if let reason = entry.turnedOffReason {
                        ReasonBox(kind: .stopped, text: reason) {
                            if entry.offersTurnOn {
                                Button("Turn On") { settings.setEnabled(entry.id, true, in: runtime) }
                            }
                        }
                    } else if let notice = entry.notice {
                        ReasonBox(kind: .warning, text: notice)
                    }
                    HStack {
                        if entry.hasOrderControls {
                            // Stock buttons with text, so the order can be changed from the keyboard.
                            Button("Move Up") { settings.move(entry.id, to: index - 1, in: runtime) }
                                .disabled(index == 0)
                            Button("Move Down") { settings.move(entry.id, to: index + 1, in: runtime) }
                                .disabled(index == entries.count - 1)
                        }
                        Spacer()
                        if entry.isRemovable, installer != nil {
                            if entry.review == nil {
                                Button("Update\u{2026}") { choosePackage(updating: entry.id) }
                            }
                            Button("Remove", role: .destructive) { removing = entry }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(entry.accessibilityLabel)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("When two blocks want the notch at once, the higher one gets it.")
                    Text("A block that is off receives no events and shows nothing in the notch.")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if installer != nil {
                Section {
                    HStack {
                        Text("Add a block you built or trust, from a .mantelblock folder.")
                        Spacer()
                        Button(EmptyBlocksAction.installBlock.title) { choosePackage() }
                    }
                } footer: {
                    if let folder = installer?.blocksFolder {
                        Text(BlockEntry.blocksFolderNote(folder))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ entry: BlockEntry) -> some View {
        Toggle(isOn: Binding(
            get: { settings.isEnabled(entry.id) },
            set: { settings.setEnabled(entry.id, $0, in: runtime) }
        )) {
            entryLabel(entry)
        }
    }

    /// A block waiting for review: no switch, a "Review…" button instead.
    private func reviewRow(_ entry: BlockEntry) -> some View {
        HStack {
            entryLabel(entry)
            Spacer()
            if entry.offersReview {
                Button("Review\u{2026}") { review(entry.id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.accessibilityLabel)
    }

    /// The icon, the title with its badge, then the summary or why it waits
    /// for review, the detail line and the usage line.
    private func entryLabel(_ entry: BlockEntry) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                    if let badge = entry.badge {
                        // A word, not a color alone.
                        Text(badge)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                }
                if let text = entry.reviewText {
                    Text(text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !entry.info.summary.isEmpty {
                    Text(entry.info.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let usage = entry.usageLine {
                    Text(usage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            // Fixed width, so titles line up whatever the symbol's shape.
            Image(systemName: entry.info.symbol).frame(width: 22)
        }
    }

    /// Shows the sheet for a block waiting for review, from its package
    /// where it is, or why it cannot be approved.
    private func review(_ id: BlockID) {
        guard let installer else { return }
        do {
            pending = PendingInstall(request: .review(id), summary: try installer.reviewSummary(id))
        } catch {
            failure = Failure(title: "The block cannot be approved", message: error.localizedDescription)
        }
    }

    /// Reads the example block for the sheet, as `choosePackage` reads a chosen one.
    private func chooseExample() {
        guard let example else { return }
        do {
            pending = try example.choose()
        } catch {
            failure = Failure(title: "The block cannot be installed", message: error.localizedDescription)
        }
    }

    /// Asks for a `.mantelblock` folder, then shows what it contains, or why it
    /// is refused. With `id`, from a row's "Update…", only that block's package is accepted.
    private func choosePackage(updating id: BlockID? = nil) {
        guard let installer else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Block"
        panel.message = "Choose a .mantelblock folder."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pending = try PendingInstall.install(url, updating: id, with: installer)
        } catch {
            failure = Failure(title: "The block cannot be installed", message: error.localizedDescription)
        }
    }

    private func remove(_ id: BlockID) {
        do {
            try installer?.remove(id)
        } catch {
            failure = Failure(title: "The block was not fully removed", message: error.localizedDescription)
        }
    }
}

extension BlockPackageSummary {
    /// Why this package cannot update the block `id`, or nil when it can.
    /// Nil `id`, from "Install Block…", accepts any package.
    func refusal(updating id: BlockID?) -> BlockInstallError? {
        guard let id, id != self.id else { return nil }
        return .differentBlock(expected: id.rawValue, found: self.id.rawValue)
    }
}

/// A refusal or failure, shown in an alert.
struct Failure {
    let title: String
    let message: String
}

extension View {
    /// The review sheet for `pending`, which installs or approves only the
    /// build it showed, and the alert for `failure`. One wiring for the
    /// Blocks page and the onboarding example row.
    func installReview(_ pending: Binding<PendingInstall?>, failure: Binding<Failure?>,
                       installer: (any BlockInstalling)?) -> some View {
        sheet(item: pending) { shown in
            BlockInstallSheet(summary: shown.summary, review: shown.isReview) {
                pending.wrappedValue = nil
                guard let installer else { return }
                do {
                    try shown.confirm(with: installer)
                } catch {
                    failure.wrappedValue = Failure(
                        title: shown.isReview ? "The block was not approved" : "The block was not installed",
                        message: error.localizedDescription)
                }
            } cancel: {
                pending.wrappedValue = nil
            }
        }
        .alert(failure.wrappedValue?.title ?? "", isPresented: Binding(
            get: { failure.wrappedValue != nil },
            set: { if !$0 { failure.wrappedValue = nil } }
        ), presenting: failure.wrappedValue) { _ in
            Button("OK", role: .cancel) {}
        } message: { shown in
            Text(shown.message)
        }
    }
}

/// A package the user chose, or one waiting for review, with what it says
/// about itself. Every install, from "Install Block…", "Update…" or
/// "Install the Example Block", is read by `install` and confirmed by `confirm`.
struct PendingInstall: Identifiable {
    enum Request: Hashable {
        /// From "Install Block…", "Install the Example Block" or "Update…": copied in when confirmed.
        case install(URL)
        /// From "Review…": approved where it is when confirmed.
        case review(BlockID)
    }

    let request: Request
    let summary: BlockPackageSummary
    var id: Request { request }
    var isReview: Bool { if case .review = request { true } else { false } }

    /// Reads the package at `url` for the sheet, or throws why it is refused.
    /// With `id`, from a row's "Update…", only that block's package is accepted.
    @MainActor
    static func install(_ url: URL, updating id: BlockID? = nil, with installer: any BlockInstalling) throws -> PendingInstall {
        let summary = try installer.inspect(url)
        if let refusal = summary.refusal(updating: id) { throw refusal }
        return PendingInstall(request: .install(url), summary: summary)
    }

    /// Installs or approves only the build the sheet showed.
    @MainActor
    func confirm(with installer: any BlockInstalling) throws {
        let hash = summary.packageHash
        switch request {
        case let .install(url): try installer.install(url, expectedHash: hash)
        case let .review(id): try installer.approve(id, expectedHash: hash)
        }
    }
}

// MARK: - Block pane

/// The block's on/off toggle, then its own pane while it is on. The pane is
/// placed inside a grouped Form section, so its controls render as rows.
private struct BlockPane: View {
    let block: any NotchBlock
    let runtime: NotchRuntime
    let settings: BlockSettings

    var body: some View {
        let id = block.id
        let isOn = settings.isEnabled(id)
        Form {
            Section {
                Toggle("On", isOn: Binding(
                    get: { settings.isEnabled(id) },
                    set: { settings.setEnabled(id, $0, in: runtime) }
                ))
            }
            if isOn, let pane = block.settingsPane {
                Section { pane }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(block.title)
    }
}

// MARK: - General pane

private struct GeneralPane: View {
    let runtime: NotchRuntime
    let consent: ScreenshotFolderConsent?
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            let rows = PermissionRow.rows(in: runtime)
            if !rows.isEmpty {
                Section("Permissions") {
                    ForEach(rows, id: \.self) { $0.view(consent: consent) }
                }
            }

            Section("Logs") {
                HStack {
                    Text("Read logs in Console.app by filtering on the subsystem \(Log.subsystem).")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Console", action: openConsole)
                }
            }

            Section {
                LabeledContent("Version", value: appVersion)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear { launchAtLogin.refresh() }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func openConsole() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
