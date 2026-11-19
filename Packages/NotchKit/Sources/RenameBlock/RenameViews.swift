import NotchCore
import SwiftUI

// White on black: the shell supplies the black shape and the dark colour
// scheme. Buttons are plain SwiftUI buttons; the panel never takes focus.

/// The rename block's accent, after nameshot.app: amber on black.
enum RenameColors {
    static let accent = Color(red: 0.961, green: 0.651, blue: 0.137)
    /// Text on the accent.
    static let onAccent = Color(red: 0.169, green: 0.090, blue: 0)
}

/// How a file name reads in the notch. Files keep their names on disk
/// (kebab-case); the notch shows words, without the extension.
enum RenameDisplay {
    /// "shelf-rename-panel-ears.png" -> "Shelf Rename Panel Ears".
    static func words(_ fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        // A name with spaces is already words (one macOS or the user gave).
        guard !stem.contains(" ") else { return stem }
        let parts = stem.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard parts.count > 1 else { return stem }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The name macOS gave it, without the extension.
    static func original(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }
}

/// The peek, in three states: naming (the screenshot with a scan line and
/// its original name), renamed (before and after, Undo and the time left to
/// undo), and failed (why the name was kept).
struct RenamePeekView: View {
    let model: RenameModel
    /// How long Undo stays; drawn as a bar that empties. Nil hides the bar.
    let undoWindow: Duration?
    let undo: @MainActor () -> Void

    var body: some View {
        HStack(spacing: NotchStyle.spacing) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if showsSparkle {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(RenameColors.accent)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(NotchStyle.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                subtitle
                    .font(NotchStyle.secondary)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, NotchStyle.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if case .renamed = model.phase, let undoWindow {
                UndoTimeBar(window: undoWindow)
                    .padding(.horizontal, NotchStyle.padding)
                    .padding(.bottom, 4)
            }
        }
        .foregroundStyle(.white)
    }

    private var showsSparkle: Bool {
        switch model.phase {
        case .idle, .naming, .renamed: true
        case .failed: false
        }
    }

    private var title: String {
        switch model.phase {
        case .idle, .naming: "Reading the screenshot\u{2026}"
        case let .renamed(item): RenameDisplay.words(item.newName)
        case .failed: "Kept the original name"
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch model.phase {
        case .idle, .naming:
            Text(model.currentName.map(RenameDisplay.original) ?? "")
        case let .renamed(item):
            Text("was ") + Text(RenameDisplay.original(item.originalName)).strikethrough()
        case let .failed(message):
            Text(message)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.phase {
        case .renamed:
            Button(action: undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(UndoButtonStyle())
        case .idle, .naming, .failed:
            if model.waiting > 0 {
                Text("+\(model.waiting) next")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.7)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        let side = NotchStyle.leadingImageSize
        let corner = RoundedRectangle(cornerRadius: NotchStyle.leadingImageRadius, style: .continuous)
        ZStack {
            if let thumbnail = model.thumbnail {
                Image(decorative: thumbnail.image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                corner.fill(.white.opacity(0.12))
                Image(systemName: isFailed ? "exclamationmark.triangle" : "camera.viewfinder")
                    .font(.system(size: 15))
                    .foregroundStyle(isFailed ? RenameColors.accent : .white.opacity(0.8))
            }
            if case .naming = model.phase { ScanLine() }
        }
        .frame(width: side, height: side)
        .clipShape(corner)
    }

    private var isFailed: Bool {
        if case .failed = model.phase { true } else { false }
    }
}

/// Undo, filled with the accent: the one action of a finished rename.
private struct UndoButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(RenameColors.onAccent)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(RenameColors.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

/// An accent line that sweeps up and down the thumbnail while it is read.
private struct ScanLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var atBottom = false

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(RenameColors.accent)
                .frame(height: 2)
                .shadow(color: RenameColors.accent, radius: 3)
                .offset(y: reduceMotion ? proxy.size.height / 2 : (atBottom ? proxy.size.height - 4 : 2))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { atBottom = true }
        }
        .accessibilityHidden(true)
    }
}

/// A thin bar that empties over the Undo window.
///
/// Shortcut: it restarts from full when the peek is shown again after a
/// hover, although the window only paused; the block is not told how much
/// time is left. Fix by passing the remaining time if that proves confusing.
private struct UndoTimeBar: View {
    let window: Duration
    @State private var progress = 1.0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(RenameColors.accent).frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 2)
        .onAppear {
            let seconds = Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
            withAnimation(.linear(duration: seconds)) { progress = 0 }
        }
        .accessibilityHidden(true)
    }
}

/// The panel on hover: recent renames, newest first, each with its old name.
struct RenameRecentsView: View {
    let model: RenameModel
    let revert: @MainActor (RecentRename) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Recent renames")
                        .font(NotchStyle.title)
                    Spacer()
                    if model.phase == .naming {
                        Text(model.waiting > 0 ? "Naming\u{2026} +\(model.waiting)" : "Naming\u{2026}")
                            .font(NotchStyle.secondary)
                            .foregroundStyle(RenameColors.accent)
                    }
                }
                Text("Every rename can go back to its old name")
                    .font(NotchStyle.secondary)
                    .foregroundStyle(.white.opacity(0.55))
            }
            if let message = model.listMessage {
                Text(message)
                    .font(NotchStyle.secondary)
                    .foregroundStyle(RenameColors.accent)
                    .lineLimit(1)
            }
            if model.recents.isEmpty {
                Text("New screenshots are named here.")
                    .font(NotchStyle.body)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(model.recents.enumerated()), id: \.element.id) { index, item in
                            RecentRenameRow(item: item, isNewest: index == 0, revert: revert)
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
    let isNewest: Bool
    let revert: @MainActor (RecentRename) -> Void

    var body: some View {
        let canRevert = !item.reverted && FileManager.default.fileExists(atPath: item.renamedURL.path)
        HStack(spacing: NotchStyle.spacing) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if isNewest && !item.reverted {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(RenameColors.accent)
                            .accessibilityHidden(true)
                    }
                    Text(item.reverted ? RenameDisplay.original(item.originalName) : RenameDisplay.words(item.newName))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(item.reverted ? 0.55 : 1))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(detail)
                    .font(NotchStyle.secondary)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.reverted {
                Text("Reverted")
                    .font(NotchStyle.body)
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Button("Revert") { revert(item) }
                    .buttonStyle(.notchCapsule)
                    .disabled(!canRevert)
                    .opacity(canRevert ? 1 : 0.4)
            }
        }
    }

    private var detail: String {
        if item.reverted { return "Name undone \u{00B7} was \(RenameDisplay.words(item.newName))" }
        let when = item.renamedAt.formatted(.relative(presentation: .named))
        return "\(RenameDisplay.original(item.originalName)) \u{00B7} \(when)"
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
