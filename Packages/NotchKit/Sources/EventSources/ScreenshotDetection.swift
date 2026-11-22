import Foundation

// Pure parts of the screenshot watcher, kept apart so tests need no folder
// events. Measured in the naming spike (`spikes/FINDINGS.md`, results table C).

/// Decides whether a new file in the folder is a screenshot to publish.
enum ScreenshotCandidate {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "pdf"]
    /// Set by macOS on every screenshot file. A binary plist holding a boolean.
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
    /// Set by a block on a screenshot file it gave a new name, to the old
    /// name. Such files are not new screenshots. Documented in `PROTOCOL.md`.
    static let originalNameAttribute = "com.topnotch.original-name"

    /// A visible image file. macOS writes a hidden `.Screenshot …` file first
    /// and renames it to the final name; the hidden one is never a candidate.
    static func isCandidateName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    /// What the watcher reads about one candidate file.
    struct Facts: Sendable, Equatable {
        var exists: Bool
        var size: Int64
        var createdAt: Date?
        /// `nil` while the attribute is absent (it can land just after the file).
        var isScreenCapture: Bool?
        /// True when the file carries `originalNameAttribute`.
        var isRenamedByBlock: Bool
    }

    enum Decision: Sendable, Equatable {
        case publish
        /// Not ready yet (no size or no screen-capture attribute). Look again soon.
        case retry
        case ignore
    }

    static func decide(_ facts: Facts, startedAt: Date) -> Decision {
        guard facts.exists else { return .ignore }
        if facts.isRenamedByBlock { return .ignore }
        if let created = facts.createdAt, created < startedAt { return .ignore }
        if facts.isScreenCapture == false { return .ignore }
        guard facts.isScreenCapture == true, facts.size > 0 else { return .retry }
        return .publish
    }

    /// The screen-capture attribute value: a binary plist boolean, or a number
    /// or string on older systems. `nil` when it cannot be read.
    static func parseScreenCaptureFlag(_ data: Data) -> Bool? {
        let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return text == "1" || text.lowercased() == "true"
        default: return nil
        }
    }

    /// Read the facts from disk.
    static func facts(at url: URL) -> Facts {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return Facts(exists: false, size: 0, createdAt: nil, isScreenCapture: nil, isRenamedByBlock: false)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let flag = readAttribute(path, screenCaptureAttribute).flatMap(parseScreenCaptureFlag)
        return Facts(
            exists: true,
            size: size,
            createdAt: attributes[.creationDate] as? Date,
            isScreenCapture: flag,
            isRenamedByBlock: readAttribute(path, originalNameAttribute) != nil
        )
    }

    static func readAttribute(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(path, name, buffer.baseAddress, size, 0, 0)
        }
        guard read >= 0 else { return nil }
        return data.prefix(read)
    }
}

/// Remembers the folder listing and the names already published, so each
/// screenshot is published once.
struct ScreenshotTracker: Sendable {
    let startedAt: Date
    private(set) var known: Set<String>
    private(set) var published: Set<String> = []

    init(startedAt: Date, existing: [String] = []) {
        self.startedAt = startedAt
        self.known = Set(existing)
    }

    /// Names in `listing` that were not in the previous listing, sorted.
    /// The listing becomes the new baseline, so a name that leaves and comes
    /// back is reported again (publishing still happens once, see `markPublished`).
    mutating func added(in listing: [String]) -> [String] {
        let now = Set(listing)
        let added = now.subtracting(known)
        known = now
        return added.sorted()
    }

    /// True the first time a name is published, false after that.
    mutating func markPublished(_ name: String) -> Bool {
        published.insert(name).inserted
    }
}
