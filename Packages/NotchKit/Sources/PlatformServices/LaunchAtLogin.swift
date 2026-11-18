import Observation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`. Errors are kept in
/// `lastError` so the settings window can show them next to the toggle.
@MainActor
@Observable
public final class LaunchAtLogin {
    public private(set) var isEnabled = false
    public private(set) var lastError: String?

    public init() {
        refresh()
    }

    public func setEnabled(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.platform.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Read the current status from the system. The user can change it in
    /// System Settings at any time, so the settings window calls this on appear.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        if status == .requiresApproval {
            lastError = "Allow TopNotch in System Settings > General > Login Items."
        }
    }
}
