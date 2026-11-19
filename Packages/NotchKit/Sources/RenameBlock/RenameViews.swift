import NotchCore
import SwiftUI

// White on black: the shell supplies the black shape and the dark colour
// scheme. Buttons are plain SwiftUI buttons; the panel never takes focus.

/// The peek: thumbnail, the new name with its state under it, Undo, "+N".
struct RenamePeekView: View {
    let model: RenameModel
    let undo: @MainActor () -> Void

    var body: some View {
        HStack(spacing: NotchStyle.spacing) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NotchStyle.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(NotchStyle.secondary)
                    .opacity(NotchStyle.secondaryOpacity)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if case .renamed = model.phase {
                Button("Undo") { undo() }
                    .buttonStyle(.notchCapsule(tint: .accentColor))
            }
            if model.waiting > 0 {
                Text("+\(model.waiting)")
                    .font(NotchStyle.body)
                    .monospacedDigit()
                    .opacity(NotchStyle.secondaryOpacity)
            }
        }
        .padding(.horizontal, NotchStyle.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    private var title: String {
        switch model.phase {
        case .idle, .naming: "Naming\u{2026}"
        case let .renamed(item): item.newName
        case .failed: "Not renamed"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .idle, .naming: "Reading the screenshot"
        case let .renamed(item): item.usedFallback ? "Renamed with a dated name" : "Renamed from what it shows"
        case let .failed(message): message
        }
    }

    @ViewBuilder private var thumbnail: some View {
        let side = NotchStyle.leadingImageSize
        let corner = RoundedRectangle(cornerRadius: NotchStyle.leadingImageRadius, style: .continuous)
        if let thumbnail = model.thumbnail {
            Image(decorative: thumbnail.image, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(corner)
        } else {
            corner
                .fill(.white.opacity(0.12))
                .frame(width: side, height: side)
                .overlay(Image(systemName: isFailed ? "exclamationmark.triangle" : "camera.viewfinder")
                    .font(.system(size: 15)).opacity(0.8))
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { true } else { false }
    }
}

/// Beside the notch while a screenshot is being named.
struct RenameWingView: View {
    let model: RenameModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "camera.viewfinder")
            if model.waiting > 0 {
                Text("+\(model.waiting)").monospacedDigit()
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Naming screenshot")
    }
}

/// The panel on hover: recent renames, newest first.
struct RenameRecentsView: View {
    let model: RenameModel
    let revert: @MainActor (RecentRename) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NotchStyle.spacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent renames")
                    .font(NotchStyle.title)
                Spacer()
                if model.phase == .naming {
                    Text(model.waiting > 0 ? "Naming\u{2026} +\(model.waiting)" : "Naming\u{2026}")
                        .font(NotchStyle.secondary)
                        .opacity(NotchStyle.secondaryOpacity)
                }
            }
            if let message = model.listMessage {
                Text(message)
                    .font(NotchStyle.secondary)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            if model.recents.isEmpty {
                Text("New screenshots are named here.")
                    .font(NotchStyle.body)
                    .opacity(NotchStyle.secondaryOpacity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: NotchStyle.spacing) {
                        ForEach(model.recents) { item in
                            RecentRenameRow(item: item, revert: revert)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, NotchStyle.padding)
        .padding(.top, 6)
        .padding(.bottom, NotchStyle.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }
}

private struct RecentRenameRow: View {
    let item: RecentRename
    let revert: @MainActor (RecentRename) -> Void

    var body: some View {
        let canRevert = !item.reverted && FileManager.default.fileExists(atPath: item.renamedURL.path)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.newName)
                    .font(NotchStyle.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.originalName)
                    .font(NotchStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(NotchStyle.secondaryOpacity)
            }
            Spacer(minLength: 8)
            Button(item.reverted ? "Reverted" : "Revert") { revert(item) }
                .buttonStyle(.notchCapsule)
                .disabled(!canRevert)
                .opacity(canRevert ? 1 : 0.4)
        }
    }
}

/// The block's pane in the settings window.
struct RenameSettingsView: View {
    @Bindable var settings: RenameSettings
    let model: RenameModel
    let refreshStatus: @MainActor () -> Void

    var body: some View {
        Form {
            Section("Names") {
                Picker("Name length", selection: $settings.length) {
                    ForEach(NameLength.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Language of names", selection: $settings.language) {
                    ForEach(NameLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Start names with the date", isOn: $settings.datePrefix)
                Toggle("End names with the app name", isOn: $settings.appNameSuffix)
            }
            Section("Speed") {
                Text("macOS saves a screenshot only after its floating thumbnail goes away, about 5 seconds after the capture. Naming cannot start before that. To name screenshots at once, press \u{21E7}\u{2318}5, open Options and turn off Show Floating Thumbnail.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("On-device model") {
                Text(model.modelStatus.explanation)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshStatus() }
    }
}
