import AppKit
import QuickLookUI

/// Shows files in the system Quick Look panel.
///
/// The notch panel never becomes key, so no view of ours is in the responder
/// chain to take panel control the usual way. The data source is set
/// directly and the app is activated so the preview panel can become key.
/// The Space key does not open it: the notch never takes keyboard focus.
@MainActor
final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()

    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        NSApp.activate()
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
