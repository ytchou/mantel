import AppKit
import NotchCore
import SwiftUI

/// Root of the Settings window: a sidebar with "General" first, then one entry
/// per registered block, in registration order.
public struct SettingsRootView: View {
    private let runtime: NotchRuntime
    private let settings: BlockSettings
    @State private var selection: SettingsPane? = .general

    public init(runtime: NotchRuntime, settings: BlockSettings) {
        self.runtime = runtime
        self.settings = settings
    }

    public var body: some View {
        let entries = runtime.blocks.map { BlockEntry(id: $0.id, title: $0.title, info: $0.info) }
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
                BlocksPane(entries: entries, runtime: runtime, settings: settings)
            case let .block(id):
                if let block = runtime.blocks.first(where: { $0.id == id }) {
                    BlockPane(block: block, runtime: runtime, settings: settings)
                }
            case .general, nil:
                GeneralPane()
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

enum SettingsPane: Hashable {
    case general
    case blocks
    case block(BlockID)
}

struct BlockEntry: Identifiable {
    let id: BlockID
    let title: String
    let info: BlockInfo

    /// The trigger and the permissions on one line, such as
    /// "Taking a screenshot · Needs: Access to the screenshot folder".
    var detail: String {
        var parts: [String] = []
        if !info.trigger.isEmpty { parts.append(info.trigger) }
        if !info.permissions.isEmpty { parts.append("Needs: " + info.permissions.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Blocks page

/// Every registered block with what it does, what starts it, what it needs,
/// and its on/off switch.
private struct BlocksPane: View {
    let entries: [BlockEntry]
    let runtime: NotchRuntime
    let settings: BlockSettings

    var body: some View {
        Form {
            Section {
                ForEach(entries) { entry in
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
                            Image(systemName: entry.info.symbol)
                        }
                    }
                }
            } footer: {
                Text("A block that is off receives no events and shows nothing in the notch.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Blocks")
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
