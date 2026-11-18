import Foundation

enum ShelfItemKind: String {
    case file, folder, link, text
    case promisedFile = "promised file"
}

struct ShelfItem {
    let kind: ShelfItemKind
    let fileURL: URL?   // file, folder, promised file
    let link: URL?      // link
    let text: String?   // text

    var displayValue: String {
        switch kind {
        case .file, .folder, .promisedFile: return fileURL?.path ?? "?"
        case .link: return link?.absoluteString ?? "?"
        case .text: return text ?? ""
        }
    }

    var shortTitle: String {
        switch kind {
        case .file, .folder, .promisedFile: return fileURL?.lastPathComponent ?? "?"
        case .link: return link?.host() ?? link?.absoluteString ?? "?"
        case .text:
            let t = (text ?? "").replacingOccurrences(of: "\n", with: " ")
            return t.count > 18 ? String(t.prefix(18)) + "..." : t
        }
    }
}
