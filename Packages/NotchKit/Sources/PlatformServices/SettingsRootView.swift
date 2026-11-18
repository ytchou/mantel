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
        let entries = runtime.blocks.map { BlockEntry(id: $0.id, title: $0.title) }
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag(SettingsPane.general)
                if !entries.isEmpty {
                    Section("Blocks") {
                        ForEach(entries) { entry in
                            Label(entry.title, systemImage: "square.grid.2x2").tag(SettingsPane.block(entry.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch selection {
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
    case block(BlockID)
}

private struct BlockEntry: Identifiable {
    let id: BlockID
    let title: String
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
