import NotchCore

/// Decides when a drag session starts and ends from raw mouse and drag
/// pasteboard signals. Pure: no AppKit, no clock.
///
/// A session starts when, after a left mouse-down, both are seen: a dragged
/// event, and a drag pasteboard change count different from the one at
/// mouse-down. A plain click-drag (selection, window move) writes no
/// pasteboard; a stale pasteboard has no movement. Neither starts a session.
/// The session ends on mouse-up.
struct DragStateMachine {
    enum Output: Equatable {
        case started
        case ended
    }

    /// Change count at the last mouse-down. `nil` while no button is held.
    private var baseline: Int?
    private var sawDragged = false
    private var sawPasteboardChange = false
    private(set) var isActive = false

    /// True between a mouse-down and the next mouse-up.
    var isArmed: Bool { baseline != nil }

    /// A left mouse-down. Ends a session still open (a missed mouse-up).
    mutating func mouseDown(changeCount: Int) -> Output? {
        let output: Output? = isActive ? .ended : nil
        isActive = false
        baseline = changeCount
        sawDragged = false
        sawPasteboardChange = false
        return output
    }

    /// A left mouse-dragged event, with the change count read at that moment.
    /// A dragged event with no mouse-down seen arms with the current count, so
    /// it cannot start a session on its own.
    mutating func dragged(changeCount: Int) -> Output? {
        if baseline == nil { _ = mouseDown(changeCount: changeCount) }
        sawDragged = true
        return observe(changeCount: changeCount)
    }

    /// The change count read by the poll timer.
    mutating func polled(changeCount: Int) -> Output? {
        guard baseline != nil else { return nil }
        return observe(changeCount: changeCount)
    }

    /// A left mouse-up, from the event monitor or the button poll.
    mutating func mouseUp() -> Output? {
        let output: Output? = isActive ? .ended : nil
        isActive = false
        baseline = nil
        sawDragged = false
        sawPasteboardChange = false
        return output
    }

    private mutating func observe(changeCount: Int) -> Output? {
        if let baseline, changeCount != baseline { sawPasteboardChange = true }
        guard !isActive, sawDragged, sawPasteboardChange else { return nil }
        isActive = true
        return .started
    }
}

/// Kinds of content on the drag pasteboard, from the types of each item.
///
/// One kind per item, most specific first: a file URL or file promise is a
/// file (a file URL item may also list a plain URL type), a URL is a link,
/// a string is text.
func dragKinds(itemTypes: [[String]]) -> Set<DropKind> {
    var kinds: Set<DropKind> = []
    for types in itemTypes {
        let set = Set(types)
        if !set.isDisjoint(with: DragPasteboardTypes.file) {
            kinds.insert(.file)
        } else if set.contains(DragPasteboardTypes.url) {
            kinds.insert(.link)
        } else if !set.isDisjoint(with: DragPasteboardTypes.text) {
            kinds.insert(.text)
        }
    }
    return kinds
}

/// Pasteboard type identifiers, as raw strings so the logic stays AppKit-free.
enum DragPasteboardTypes {
    static let file: Set<String> = [
        "public.file-url",
        "NSFilenamesPboardType",
        // File promises, as listed by NSFilePromiseReceiver.readableDraggedTypes.
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-suggested-file-name",
        "Apple files promise pasteboard type",
        "NSPromiseContentsPboardType",
    ]
    static let url = "public.url"
    static let text: Set<String> = ["public.utf8-plain-text", "public.plain-text", "NSStringPboardType"]
}
