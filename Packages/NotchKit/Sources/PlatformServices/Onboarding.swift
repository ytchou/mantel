import AppKit
import Foundation
import NotchCore
import Observation
import SwiftUI

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

/// The answer to "may TopNotch read the screenshot folder", asked through
/// `FolderAccess.check` before the screenshot source first runs, and again
/// each time the owner presses "Allow access". The app wires it as the
/// source's consent check and sets `onChange` to the source coordinator's
/// `evaluate`. Kept for this launch only: each launch asks again, and macOS
/// answers at once once the user has decided.
@MainActor
@Observable
public final class ScreenshotFolderConsent {
    public private(set) var isGranted = false
    /// True once an answer came in that is not "allowed". The Blocks page
    /// then says why a block that needs the folder does nothing.
    public private(set) var isRefused = false
    /// Called after every answer; the app passes the source coordinator's `evaluate`.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var isAsking = false

    public init() {}

    /// Ask macOS for access to the screenshot folder. An ask while one is
    /// under way does nothing.
    public func ask() {
        guard !isAsking else { return }
        isAsking = true
        Task {
            let access = await FolderAccess.check(ScreenshotFolder.current())
            isAsking = false
            record(access)
        }
    }

    /// Checks `folder` again, as "Allow access" does, and records the answer.
    func check(_ folder: URL) async -> FolderAccess {
        let access = await FolderAccess.check(folder)
        record(access)
        return access
    }

    /// Keeps `access` as the answer and reports it through `onChange`.
    func record(_ access: FolderAccess) {
        isGranted = access == .granted
        isRefused = !isGranted
        onChange?()
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

/// A permission row on the General page and in onboarding.
enum PermissionRow: Hashable {
    case screenshotFolder
    case appleIntelligence

    /// The rows to show: the screenshot folder only while a turned-on block
    /// listens to `ScreenshotCaptured`, since only then does its source run.
    @MainActor
    static func rows(in runtime: NotchRuntime) -> [PermissionRow] {
        (runtime.hasSubscribers(for: ScreenshotCaptured.self) ? [.screenshotFolder] : []) + [.appleIntelligence]
    }

    /// - Parameter consent: updated when the owner presses "Allow access".
    @MainActor @ViewBuilder func view(consent: ScreenshotFolderConsent?) -> some View {
        switch self {
        case .screenshotFolder: FolderAccessRow(consent: consent)
        case .appleIntelligence: AppleIntelligenceRow()
        }
    }
}

struct FolderAccessRow: View {
    @State private var access: FolderAccess = .unknown
    let folder = ScreenshotFolder.current()
    /// Takes the answer, so the screenshot source starts once access is allowed.
    let consent: ScreenshotFolderConsent?

    init(consent: ScreenshotFolderConsent? = nil) {
        self.consent = consent
    }

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
                            if let consent {
                                access = await consent.check(folder)
                            } else {
                                access = await FolderAccess.check(folder)
                            }
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
    private let rows: [PermissionRow]
    private let consent: ScreenshotFolderConsent?
    private let onDone: () -> Void

    init(rows: [PermissionRow], consent: ScreenshotFolderConsent? = nil, onDone: @escaping () -> Void) {
        self.rows = rows
        self.consent = consent
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to TopNotch").font(.title2.bold())
                Text("TopNotch works from the notch and the menu bar. What needs your OK is below. You can come back to it in Settings > General. To open Settings, right-click the notch.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)

            Form {
                ForEach(rows, id: \.self) { row in
                    Section { row.view(consent: consent) }
                }
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

    private let runtime: NotchRuntime
    private let consent: ScreenshotFolderConsent?
    private let defaults: UserDefaults
    private var window: NSWindow?

    /// - Parameter consent: updated when the owner presses "Allow access".
    public init(runtime: NotchRuntime, consent: ScreenshotFolderConsent? = nil, defaults: UserDefaults = .standard) {
        self.runtime = runtime
        self.consent = consent
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
        // Measure once, then give the window a fixed size. Letting the hosting
        // view drive the window size through constraints crashed at launch
        // (AppKit exception in the window's update-constraints pass).
        let hosting = NSHostingView(rootView: OnboardingView(rows: PermissionRow.rows(in: runtime), consent: consent) { [weak self] in
            self?.window?.close()
        })
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
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
