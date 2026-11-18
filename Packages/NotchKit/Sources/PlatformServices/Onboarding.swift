import AppKit
import Foundation
import SwiftUI

// MARK: - Screenshot folder

enum ScreenshotFolder {
    /// The folder macOS saves screenshots to.
    static func current() -> URL {
        resolve(location: UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
                home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// `location` as stored by macOS, with a leading `~` expanded against
    /// `home`. Missing or empty means `~/Desktop`.
    static func resolve(location: String?, home: URL) -> URL {
        guard let location, !location.isEmpty else {
            return home.appending(path: "Desktop", directoryHint: .isDirectory)
        }
        if location == "~" { return home }
        if location.hasPrefix("~/") {
            return home.appending(path: String(location.dropFirst(2)), directoryHint: .isDirectory)
        }
        return URL(filePath: location, directoryHint: .isDirectory)
    }
}

// MARK: - Folder access

enum FolderAccess: Equatable, Sendable {
    case unknown
    case checking
    case granted
    case denied
    case failed(String)

    /// List the folder. The first time, macOS shows its access prompt; the call
    /// waits for the answer, so it runs off the main thread.
    static func check(_ folder: URL) async -> FolderAccess {
        await Task.detached { () -> FolderAccess in
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                return .granted
            } catch {
                let error = error as NSError
                return isPermissionError(error) ? .denied : .failed(error.localizedDescription)
            }
        }.value
    }

    /// A read refused by macOS privacy controls: Cocoa "no permission", or
    /// POSIX EPERM / EACCES directly or as the underlying error.
    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return true }
        let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let posix, posix.domain == NSPOSIXErrorDomain else { return false }
        return posix.code == Int(EPERM) || posix.code == Int(EACCES)
    }
}

enum SystemSettings {
    static let filesAndFolders = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    static let appleIntelligence = "x-apple.systempreferences:com.apple.Siri-Settings.extension"

    @MainActor
    static func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Permission rows (used by onboarding and Settings > General)

struct FolderAccessRow: View {
    @State private var access: FolderAccess = .unknown
    private let folder = ScreenshotFolder.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screenshot folder").font(.headline)
            Text("TopNotch gives new screenshots clear names. To do that it reads the folder screenshots are saved to (\((folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)). macOS asks once whether TopNotch may use that folder.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                status
                Spacer()
                if access == .denied {
                    Button("Open System Settings") { SystemSettings.open(SystemSettings.filesAndFolders) }
                } else if access != .granted {
                    Button("Allow access") {
                        Task {
                            access = .checking
                            access = await FolderAccess.check(folder)
                        }
                    }
                    .disabled(access == .checking)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch access {
        case .unknown:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Label("Not allowed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

struct AppleIntelligenceRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apple Intelligence").font(.headline)
            Text("Naming screenshots on this Mac uses Apple Intelligence. Turn it on and let its model download, which takes several minutes. Without it, screenshots still get a tidy name with the date.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Open Apple Intelligence Settings") { SystemSettings.open(SystemSettings.appleIntelligence) }
            }
        }
    }
}

// MARK: - Onboarding

/// First-run onboarding window content, also reachable from
/// Settings > General > Permissions.
public struct OnboardingView: View {
    private let onDone: () -> Void

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to TopNotch").font(.title2.bold())
                Text("TopNotch works from the notch and the menu bar. Two things need your OK first. You can come back to them in Settings > General.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section { FolderAccessRow() }
                Section { AppleIntelligenceRow() }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
    }
}

/// Shows the onboarding window once (UserDefaults key "onboarding.completed").
@MainActor
public final class OnboardingController: NSObject, NSWindowDelegate {
    static let completedKey = "onboarding.completed"

    private let defaults: UserDefaults
    private var window: NSWindow?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    var isCompleted: Bool { defaults.bool(forKey: Self.completedKey) }

    func markCompleted() {
        defaults.set(true, forKey: Self.completedKey)
    }

    public func showIfNeeded() {
        guard !isCompleted else { return }
        show()
    }

    public func show() {
        // The app has no Dock icon; without activating, the window opens behind others.
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView { [weak self] in self?.window?.close() })
        hosting.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Welcome to TopNotch"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Closing the window, with Done or the close button, counts as seen.
    public func windowWillClose(_ notification: Notification) {
        markCompleted()
        window = nil
    }
}
