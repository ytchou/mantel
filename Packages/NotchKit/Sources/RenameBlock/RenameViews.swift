import SwiftUI

// White on black: the shell supplies the black shape and the dark colour
// scheme. Buttons are plain SwiftUI buttons; the panel never takes focus.

/// The strip under the notch: thumbnail, state, Undo, "+N".
struct RenamePeekView: View {
    let model: RenameModel
    let undo: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
            content
            if model.waiting > 0 {
                Text("+\(model.waiting)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .opacity(0.7)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var thumbnail: some View {
        if let thumbnail = model.thumbnail {
            Image(decorative: thumbnail.image, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.15))
                .frame(width: 30, height: 24)
                .overlay(Image(systemName: "camera.viewfinder").font(.system(size: 11)).opacity(0.7))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .naming:
            Text("Naming\u{2026}")
                .font(.system(size: 12, weight: .medium))
                .opacity(0.8)
            Spacer(minLength: 0)
        case let .renamed(item):
            Text(item.newName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Undo") { undo() }
                .modifier(NotchButton())
        case let .failed(message):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .opacity(0.8)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent renames")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.phase == .naming {
                    Text(model.waiting > 0 ? "Naming\u{2026} +\(model.waiting)" : "Naming\u{2026}")
                        .font(.system(size: 11))
                        .opacity(0.7)
                }
            }
            if let message = model.listMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            if model.recents.isEmpty {
                Text("New screenshots are named here.")
                    .font(.system(size: 12))
                    .opacity(0.6)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.recents) { item in
                            RecentRenameRow(item: item, revert: revert)
                        }
                    }
                }
            }
        }
        .padding(12)
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
            VStack(alignment: .leading, spacing: 1) {
                Text(item.newName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.originalName)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(0.6)
            }
            Spacer(minLength: 8)
            Button(item.reverted ? "Reverted" : "Revert") { revert(item) }
                .modifier(NotchButton())
                .disabled(!canRevert)
                .opacity(canRevert ? 1 : 0.4)
        }
    }
}

/// A small capsule button that reads well on black.
private struct NotchButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.18)))
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
