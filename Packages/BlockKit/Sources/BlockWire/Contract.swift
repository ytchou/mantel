import Foundation

/// The version of the wire protocol, and its limits.
///
/// A block names its version in `manifest.json` and in `hello`. The app
/// refuses a block whose version is outside `supported`.
public enum Contract {
    /// The version this code speaks.
    public static let current = 1
    /// The versions the app accepts.
    public static let supported: ClosedRange<Int> = 1...1

    /// The largest frame body, in bytes. A larger frame is an error.
    public static let maxFrameBytes = 4 * 1024 * 1024
    /// The most nodes one view tree may hold.
    public static let maxNodes = 200
    /// The app keeps this many images per block. The kit resends an image
    /// that is no longer among the last this many it sent.
    public static let assetCacheSize = 8
}
