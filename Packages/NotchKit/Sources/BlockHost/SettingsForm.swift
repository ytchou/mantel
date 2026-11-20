import BlockWire
import SwiftUI

/// A block's settings, drawn by the app from its manifest. The rows go inside
/// a grouped `Form` section, where the settings window places a block's pane:
/// a switch for each `toggle`, a menu for each `choice`, and secondary text
/// for each `note`. Values are read from and written through the stand-in,
/// which stores them as `<id>.<key>` and tells the running block.
struct SettingsForm: View {
    let block: RemoteBlock

    var body: some View {
        ForEach(block.manifest.settings, id: \.key) { spec in
            switch spec.type {
            case .toggle:
                Toggle(spec.title, isOn: toggle(spec.key))
            case .choice:
                Picker(spec.title, selection: choice(spec.key)) {
                    ForEach(spec.options ?? [], id: \.value) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            case .note:
                Text(spec.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A toggle's value. Unknown keys read as on, as an unset toggle does.
    func toggle(_ key: String) -> Binding<Bool> {
        let block = block
        return Binding(
            get: { block.settings[key]?.bool ?? true },
            set: { block.setSetting(key, to: .bool($0)) }
        )
    }

    /// A choice's value: the selected option's `value`.
    func choice(_ key: String) -> Binding<String> {
        let block = block
        return Binding(
            get: { block.settings[key]?.string ?? "" },
            set: { block.setSetting(key, to: .string($0)) }
        )
    }
}
