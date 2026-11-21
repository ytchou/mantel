import Foundation

// The one definition of the screenshot folder: the screenshot watcher reads
// it, the settings rows ask for access to it and `files.screenshots` opens it.

/// Where macOS saves screenshots.
public enum ScreenshotFolder {
    static let defaultsDomain = "com.apple.screencapture"
    static let defaultsKey = "location"

    /// The folder from the `location` value of `com.apple.screencapture`,
    /// with a leading `~` expanded against `home`. Falls back to `~/Desktop`
    /// when the value is missing, empty or not an existing folder.
    public static func resolve(location: String?, home: URL, isDirectory: (URL) -> Bool) -> URL {
        let desktop = home.appending(path: "Desktop", directoryHint: .isDirectory)
        guard let raw = location?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return desktop
        }
        let path: String
        if raw == "~" {
            path = home.path
        } else if raw.hasPrefix("~/") {
            path = home.path + "/" + String(raw.dropFirst(2))
        } else {
            path = raw
        }
        let url = URL(filePath: path, directoryHint: .isDirectory)
        return isDirectory(url) ? url : desktop
    }

    /// Read the user's setting now. Synchronises first, so a change made with
    /// `defaults write` or the Screenshot app since the last read is seen.
    public static func current() -> URL {
        let domain = defaultsDomain as CFString
        CFPreferencesAppSynchronize(domain)
        let location = CFPreferencesCopyAppValue(defaultsKey as CFString, domain) as? String
        return resolve(location: location, home: FileManager.default.homeDirectoryForCurrentUser) { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
