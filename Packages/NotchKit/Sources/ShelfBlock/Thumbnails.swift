import AppKit
import QuickLookThumbnailing
import SwiftUI

/// File thumbnails from Quick Look, cached by path. The Finder icon is the
/// placeholder until the thumbnail arrives, and the final image for folders
/// and files Quick Look cannot draw.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var images: [String: NSImage] = [:]
    /// Whole cache is dropped when it grows past this; a shelf rarely holds
    /// more. Switch to an LRU if shelves get large.
    private static let limit = 200

    func cached(for url: URL) -> NSImage? { images[url.path(percentEncoded: false)] }

    func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }

    /// The Quick Look thumbnail, or nil when there is none.
    func thumbnail(for url: URL, side: CGFloat) async -> NSImage? {
        let key = url.path(percentEncoded: false)
        if let image = images[key] { return image }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .thumbnail)
        let box = await withCheckedContinuation { (continuation: CheckedContinuation<ImageBox?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation.map { ImageBox(image: $0.cgImage) })
            }
        }
        guard let cgImage = box?.image else { return nil }
        let image = NSImage(cgImage: cgImage, size: CGSize(width: CGFloat(cgImage.width) / scale,
                                                           height: CGFloat(cgImage.height) / scale))
        if images.count >= Self.limit { images.removeAll() }
        images[key] = image
        return image
    }
}

/// Carries a thumbnail from Quick Look's queue to the main actor. A `CGImage`
/// is immutable, so sharing it across threads is safe.
private struct ImageBox: @unchecked Sendable {
    let image: CGImage
}

/// A file's thumbnail, starting with its Finder icon.
struct FileThumbnail: View {
    let url: URL
    let side: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        let cache = ThumbnailCache.shared
        Image(nsImage: thumbnail ?? cache.cached(for: url) ?? cache.icon(for: url))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .task(id: url) {
                guard !isFolder else { return }
                if let image = await cache.thumbnail(for: url, side: side) { thumbnail = image }
            }
    }

    private var isFolder: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
