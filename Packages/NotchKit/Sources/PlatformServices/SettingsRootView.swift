import AppKit
import NotchCore
import SwiftUI

/// Root of the Settings window: a sidebar with "General" and "Blocks" first,
/// then one entry per registered block, in rank order.
public struct SettingsRootView: View {
    private let runtime: NotchRuntime
    private let settings: BlockSettings
    private let installer: (any BlockInstalling)?
    @State private var selection: SettingsPane?

    /// - Parameter installer: installs, updates and removes blocks from the
    ///   Blocks page. Nil hides those buttons.
    public init(runtime: NotchRuntime, settings: BlockSettings, installer: (any BlockInstalling)? = nil) {
        self.init(runtime: runtime, settings: settings, installer: installer, selection: .general)
    }

    /// Opens on a chosen pane. Internal, for checking a pane without clicking.
    init(runtime: NotchRuntime, settings: BlockSettings, installer: (any BlockInstalling)? = nil, selection: SettingsPane) {
        self.runtime = runtime
        self.settings = settings
        self.installer = installer
        _selection = State(initialValue: selection)
    }

    public var body: some View {
        // Built here, inside `body`, so a block's health and info are read
        // live: the page redraws when a stand-in's observable state changes.
        let entries = runtime.blocks.map { BlockEntry(block: $0, installer: installer) }
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag(SettingsPane.general)
                Label("Blocks", systemImage: "square.grid.2x2").tag(SettingsPane.blocks)
                if !entries.isEmpty {
                    Section("Block Settings") {
                        ForEach(entries) { entry in
                            Label(entry.title, systemImage: entry.info.symbol).tag(SettingsPane.block(entry.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch selection {
            case .blocks:
                BlocksPane(entries: entries, runtime: runtime, settings: settings, installer: installer)
            case let .block(id):
                if let block = runtime.blocks.first(where: { $0.id == id }) {
                    BlockPane(block: block, runtime: runtime, settings: settings)
                }
            case .general, nil:
                GeneralPane()
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
    /// Shown as "~" at the start of a path.
    let home: String

    init(id: BlockID, title: String, info: BlockInfo, health: BlockHealth = .ok, isRemovable: Bool = false,
         canTurnOn: Bool = true, home: String = NSHomeDirectory()) {
        self.id = id
        self.title = title
        self.info = info
        self.health = health
        self.isRemovable = isRemovable
        self.canTurnOn = canTurnOn
        self.home = home
    }

    /// Reads the block's state now. Call it inside `body` so changes redraw.
    @MainActor
    init(block: any NotchBlock, installer: (any BlockInstalling)?, home: String = NSHomeDirectory()) {
        self.init(id: block.id, title: block.title, info: block.info, health: block.health,
                  isRemovable: installer?.canRemove(block.id) ?? false,
                  canTurnOn: installer?.canTurnOn(block.id) ?? true, home: home)
    }

    /// Where the block comes from, its version, the trigger, the permissions
    /// and recent restarts on one line, such as
    /// "Built in · Taking a screenshot · Needs: Access to the screenshot folder"
    /// or "Installed from ~/dev/hello-block · 0.2 · Pointer hover · Restarted once".
    var detail: String {
        var parts: [String] = []
        switch info.source {
        case .builtIn, .bundled: parts.append("Built in")
        case let .installed(from): parts.append("Installed from " + abbreviated(from))
        case let .development(path): parts.append("Development · " + abbreviated(path))
        }
        if let version = info.version, !version.isEmpty { parts.append(version) }
        if !info.trigger.isEmpty { parts.append(info.trigger) }
        if !info.permissions.isEmpty { parts.append("Needs: " + info.permissions.joined(separator: ", ")) }
        if case let .restarting(count) = health {
            parts.append(count == 1 ? "Restarted once" : "Restarted \(count) times")
        }
        return parts.joined(separator: " · ")
    }

    /// Why the app turned the block off, or nil.
    var turnedOffReason: String? {
        if case let .turnedOff(reason) = health { return reason }
        return nil
    }

    /// A "Turn On" button is shown while the app has turned the block off,
    /// unless turning it on cannot start it.
    var offersTurnOn: Bool { turnedOffReason != nil && canTurnOn }

    /// `path` with the home folder written as "~".
    private func abbreviated(_ path: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Blocks page

/// Every registered block with what it does, where it comes from, what
/// starts it, what it needs, and its on/off switch. With an installer, blocks
/// the user installed can be updated and removed, and new ones installed.
private struct BlocksPane: View {
    let entries: [BlockEntry]
    let runtime: NotchRuntime
    let settings: BlockSettings
    let installer: (any BlockInstalling)?

    /// The package chosen with "Install Block…" or "Update…", waiting for confirmation.
    @State private var pending: PendingInstall?
    /// A refusal or failure, shown in an alert.
    @State private var failure: Failure?
    /// The block waiting for the user to confirm Remove.
    @State private var removing: BlockEntry?
    /// Mirrors "block.allowUnsigned", which is not observable.
    @State private var allowUnsigned: Bool

    init(entries: [BlockEntry], runtime: NotchRuntime, settings: BlockSettings, installer: (any BlockInstalling)?) {
        self.entries = entries
        self.runtime = runtime
        self.settings = settings
        self.installer = installer
        _allowUnsigned = State(initialValue: settings.allowsUnsigned)
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry)
                    if let reason = entry.turnedOffReason {
                        HStack {
                            Label("Turned off: \(reason)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if entry.offersTurnOn {
                                Button("Turn On") { settings.setEnabled(entry.id, true, in: runtime) }
                            }
                        }
                    }
                    HStack {
                        // Stock buttons with text, so the order can be changed from the keyboard.
                        Button("Move Up") { settings.move(entry.id, to: index - 1, in: runtime) }
                            .disabled(index == 0)
                        Button("Move Down") { settings.move(entry.id, to: index + 1, in: runtime) }
                            .disabled(index == entries.count - 1)
                        Spacer()
                        if entry.isRemovable, installer != nil {
                            Button("Update\u{2026}") { choosePackage(updating: entry.id) }
                            Button("Remove", role: .destructive) { removing = entry }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(entry.title)
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
                        Text("Add a block you built or trust, from a .topblock folder.")
                        Spacer()
                        Button("Install Block\u{2026}") { choosePackage() }
                    }
                }
            }
            Section {
                Toggle("Allow blocks without a signature", isOn: Binding(
                    get: { allowUnsigned },
                    set: { allowUnsigned = $0; settings.setAllowsUnsigned($0) }
                ))
            } footer: {
                Text("Nobody vouches for an unsigned block, and it could have been changed by someone else, so turn this on only for blocks you built yourself.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Blocks")
        .sheet(item: $pending) { pending in
            BlockInstallSheet(summary: pending.summary) {
                self.pending = nil
                install(pending.url)
            } cancel: {
                self.pending = nil
            }
        }
        .alert(failure?.title ?? "", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        ), presenting: failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
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

    private func row(_ entry: BlockEntry) -> some View {
        Toggle(isOn: Binding(
            get: { settings.isEnabled(entry.id) },
            set: { settings.setEnabled(entry.id, $0, in: runtime) }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                    if !entry.info.summary.isEmpty {
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
                }
            } icon: {
                // Fixed width, so titles line up whatever the symbol's shape.
                Image(systemName: entry.info.symbol).frame(width: 22)
            }
        }
    }

    /// Asks for a `.topblock` folder, then shows what it contains, or why it
    /// is refused. With `id`, from a row's "Update…", only that block's package is accepted.
    private func choosePackage(updating id: BlockID? = nil) {
        guard let installer else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Block"
        panel.message = "Choose a .topblock folder."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try installer.inspect(url)
            if let refusal = summary.refusal(updating: id) { throw refusal }
            pending = PendingInstall(url: url, summary: summary)
        } catch {
            failure = Failure(title: "The block cannot be installed", message: error.localizedDescription)
        }
    }

    private func install(_ url: URL) {
        do {
            try installer?.install(url)
        } catch {
            failure = Failure(title: "The block was not installed", message: error.localizedDescription)
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

private struct Failure {
    let title: String
    let message: String
}

/// A package the user chose, with what it says about itself.
private struct PendingInstall: Identifiable {
    let url: URL
    let summary: BlockPackageSummary
    var id: URL { url }
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

            Section("Permissions") {
                FolderAccessRow()
                AppleIntelligenceRow()
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
