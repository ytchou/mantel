import Foundation

/// TopNotch's support folder, `~/Library/Application Support/TopNotch`: the
/// root of `BlockStore`'s folders (installed packages, every block's data,
/// the approvals), which every block's sandbox closes except its own
/// package and data folder.
public enum SupportFolder {
    public static var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "TopNotch")
    }
}
