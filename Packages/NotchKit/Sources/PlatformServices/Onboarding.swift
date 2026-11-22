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

    /// The rows to show: the screenshot folder only while a turned-on block
    /// listens to `ScreenshotCaptured`, since only then does its source run.
    @MainActor
    static func rows(in runtime: NotchRuntime) -> [PermissionRow] {
        runtime.hasSubscribers(for: ScreenshotCaptured.self) ? [.screenshotFolder] : []
    }

    /// - Parameter consent: updated when the owner presses "Allow access".
    @MainActor @ViewBuilder func view(consent: ScreenshotFolderConsent?) -> some View {
        switch self {
        case .screenshotFolder: FolderAccessRow(consent: consent)
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

// MARK: - The example block

/// The kit's example block, shipped inside the app and offered by onboarding
/// and the empty Blocks page. It installs only through `BlockInstalling`,
/// with the review sheet, exactly as a package chosen with "Install Block…".
@MainActor
final class ExampleOffer {
    enum Status: Equatable {
        case notInstalled
        case installed
        /// `inspect` refused the example; the refusal in words. No install
        /// is offered: it would fail the same way.
        case unavailable(String)

        /// The status in words, not color alone.
        var text: String {
            switch self {
            case .notInstalled: "Not installed"
            case .installed: "Installed"
            case let .unavailable(reason): reason
            }
        }
    }

    /// What the first `inspect` of the example said.
    private enum Probe {
        /// The example's id, from its package or from an `idInUse` refusal.
        case id(BlockID)
        /// Any other refusal, in words.
        case refused(String)
    }

    let url: URL
    let installer: any BlockInstalling
    private var probe: Probe?

    /// Nil, so nothing is offered, without an example in the app or without an installer.
    init?(url: URL?, installer: (any BlockInstalling)?) {
        guard let url, let installer else { return nil }
        self.url = url
        self.installer = installer
    }

    /// The example's id, read from its package by `inspect`. The first
    /// outcome, refusal included, is kept, so redraws do not hash and check
    /// the package again.
    // Kept for the object's life: a refusal that later goes away, such as
    // a conflicting block removed, shows again only in a new window. Probe
    // again on `runtime.blocks` changes if that ever confuses an owner.
    private var outcome: Probe {
        if let probe { return probe }
        let read: Probe
        do {
            read = .id(try installer.inspect(url).id)
        } catch BlockInstallError.idInUse(let id) {
            // A block with the example's id runs, such as the development block.
            read = .id(BlockID(rawValue: id))
        } catch {
            read = .refused(error.localizedDescription)
        }
        probe = read
        return read
    }

    /// Installed once a block with the example's id is registered, waiting
    /// for review included.
    func status(in runtime: NotchRuntime) -> Status {
        switch outcome {
        case let .refused(reason): .unavailable(reason)
        case let .id(id): runtime.blocks.contains { $0.id == id } ? .installed : .notInstalled
        }
    }

    /// Reads the example for the review sheet, as "Install Block…" reads a chosen package.
    func choose() throws -> PendingInstall {
        try PendingInstall.install(url, with: installer)
    }
}

/// The example row in onboarding, in the `FolderAccessRow` pattern.
struct ExampleRow: View {
    let offer: ExampleOffer
    let runtime: NotchRuntime
    /// The example read for the review sheet, waiting for confirmation.
    @State private var pending: PendingInstall?
    /// Why the example could not be read or installed, shown in an alert.
    @State private var failure: Failure?
    @FocusState private var installFocused: Bool

    var body: some View {
        let status = offer.status(in: runtime)
        VStack(alignment: .leading, spacing: 6) {
            Text("Try the example block").font(.headline)
            Text("A small block that shows a greeting when the pointer reaches the notch. You can remove it at any time.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(status.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if status == .notInstalled {
                    Button(EmptyBlocksAction.installExample.title, action: choose)
                        .focused($installFocused)
                }
            }
        }
        .defaultFocus($installFocused, true)
        .installReview($pending, failure: $failure, installer: offer.installer)
    }

    private func choose() {
        do {
            pending = try offer.choose()
        } catch {
            failure = Failure(title: "The block cannot be installed", message: error.localizedDescription)
        }
    }
}

// MARK: - Onboarding

/// First-run onboarding window content: the permission rows a turned-on
/// block needs, then the offer to install the example block.
public struct OnboardingView: View {
    private let rows: [PermissionRow]
    private let consent: ScreenshotFolderConsent?
    private let example: ExampleOffer?
    private let runtime: NotchRuntime?
    private let onDone: () -> Void

    init(rows: [PermissionRow], consent: ScreenshotFolderConsent? = nil, example: ExampleOffer? = nil,
         runtime: NotchRuntime? = nil, onDone: @escaping () -> Void) {
        self.rows = rows
        self.consent = consent
        self.example = example
        self.runtime = runtime
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to TopNotch").font(.title2.bold())
                Text("TopNotch works from the notch and the menu bar. Each thing it does comes from a block you add. To open Settings, right-click the notch.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)

            Form {
                ForEach(rows, id: \.self) { row in
                    Section { row.view(consent: consent) }
                }
                if let example, let runtime {
                    Section { ExampleRow(offer: example, runtime: runtime) }
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
    private let installer: (any BlockInstalling)?
    private let exampleURL: URL?
    private let defaults: UserDefaults
    private var window: NSWindow?

    /// - Parameters:
    ///   - consent: updated when the owner presses "Allow access".
    ///   - installer, exampleURL: with both, onboarding offers the example
    ///     block, installed through the review sheet as on the Blocks page.
    public init(runtime: NotchRuntime, consent: ScreenshotFolderConsent? = nil, installer: (any BlockInstalling)? = nil,
                exampleURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.runtime = runtime
        self.consent = consent
        self.installer = installer
        self.exampleURL = exampleURL
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
        let example = ExampleOffer(url: exampleURL, installer: installer)
        let hosting = NSHostingView(rootView: OnboardingView(rows: PermissionRow.rows(in: runtime), consent: consent,
                                                             example: example, runtime: runtime) { [weak self] in
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
