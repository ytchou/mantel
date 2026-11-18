import Foundation

let originalNameXattr = "com.topnotch.original-name"

private func sameDate(_ a: Date?, _ b: Date?) -> Bool {
    guard let a, let b else { return false }
    return a.timeIntervalSinceReferenceDate == b.timeIntervalSinceReferenceDate
}

/// Moves `path` to `<newBase>.<ext>` in the same folder (collisions get -2, -3, ...),
/// keeps creation and modification dates, and stores the original file name in an xattr.
func renameKeepingDates(path: String, newBase: String) throws -> [String: Any] {
    let fm = FileManager.default
    let src = URL(fileURLWithPath: path).standardizedFileURL
    guard fm.fileExists(atPath: src.path) else { throw SpikeError("no such file: \(src.path)") }
    let base = sanitizeFileName(newBase)
    guard !base.isEmpty else { throw SpikeError("new base name is empty after sanitising: \(newBase)") }
    let ext = src.pathExtension
    let dir = src.deletingLastPathComponent()

    var target = dir.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while fm.fileExists(atPath: target.path) && target.path != src.path {
        target = dir.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
        n += 1
    }

    let before = fileDates(src.path)
    // Keep the FIRST original name across repeated renames, so undo always goes back to it.
    let existing = readXattr(src.path, originalNameXattr).flatMap { String(data: $0, encoding: .utf8) }
    let original = existing ?? src.lastPathComponent
    if existing == nil, !writeXattr(src.path, originalNameXattr, Data(original.utf8)) {
        throw SpikeError("setxattr failed: errno \(errno)")
    }

    let t0 = nowNs()
    if target.path != src.path { try fm.moveItem(at: src, to: target) }
    let moveMs = ms(since: t0)

    var after = fileDates(target.path)
    let preservedByMove = sameDate(before.created, after.created) && sameDate(before.modified, after.modified)
    var restored = false
    if !preservedByMove {
        var attrs: [FileAttributeKey: Any] = [:]
        if let c = before.created { attrs[.creationDate] = c }
        if let m = before.modified { attrs[.modificationDate] = m }
        try fm.setAttributes(attrs, ofItemAtPath: target.path)
        after = fileDates(target.path)
        restored = true
    }
    let readBack = readXattr(target.path, originalNameXattr).flatMap { String(data: $0, encoding: .utf8) }
    let identical = sameDate(before.created, after.created) && sameDate(before.modified, after.modified)

    return [
        "from": src.path,
        "to": target.path,
        "collisionSuffix": n > 2,
        "createdBefore": before.created as Any, "createdAfter": after.created as Any,
        "modifiedBefore": before.modified as Any, "modifiedAfter": after.modified as Any,
        "datesPreservedByMoveAlone": preservedByMove,
        "datesRestoredExplicitly": restored,
        "datesIdentical": identical,
        "xattrName": originalNameXattr,
        "xattrReadBack": readBack as Any,
        "xattrMatchesOriginal": readBack == original,
        "moveMs": moveMs,
        "ok": identical && readBack == original,
    ]
}

/// Restores the original name stored by `renameKeepingDates` and removes the xattr.
func undoRename(path: String) throws -> [String: Any] {
    let fm = FileManager.default
    let src = URL(fileURLWithPath: path).standardizedFileURL
    guard let data = readXattr(src.path, originalNameXattr), let original = String(data: data, encoding: .utf8), !original.isEmpty else {
        throw SpikeError("no \(originalNameXattr) attribute on \(src.path)")
    }
    let target = src.deletingLastPathComponent().appendingPathComponent(original)
    if fm.fileExists(atPath: target.path) && target.path != src.path {
        throw SpikeError("cannot undo: \(target.path) already exists")
    }
    let before = fileDates(src.path)
    if target.path != src.path { try fm.moveItem(at: src, to: target) }
    var after = fileDates(target.path)
    if !(sameDate(before.created, after.created) && sameDate(before.modified, after.modified)) {
        var attrs: [FileAttributeKey: Any] = [:]
        if let c = before.created { attrs[.creationDate] = c }
        if let m = before.modified { attrs[.modificationDate] = m }
        try fm.setAttributes(attrs, ofItemAtPath: target.path)
        after = fileDates(target.path)
    }
    removeXattr(target.path, originalNameXattr)
    let xattrGone = readXattr(target.path, originalNameXattr) == nil
    let identical = sameDate(before.created, after.created) && sameDate(before.modified, after.modified)
    return [
        "from": src.path,
        "to": target.path,
        "restoredName": original,
        "createdBefore": before.created as Any, "createdAfter": after.created as Any,
        "modifiedBefore": before.modified as Any, "modifiedAfter": after.modified as Any,
        "datesIdentical": identical,
        "xattrRemoved": xattrGone,
        "ok": identical && xattrGone,
    ]
}

func printRename(_ r: [String: Any]) {
    print("Moved: \(r["from"] ?? "") -> \(r["to"] ?? "")")
    print("Created  before: \(r["createdBefore"] ?? "nil")  after: \(r["createdAfter"] ?? "nil")")
    print("Modified before: \(r["modifiedBefore"] ?? "nil")  after: \(r["modifiedAfter"] ?? "nil")")
    print("Dates identical: \(r["datesIdentical"] ?? false)")
    if let rb = r["xattrReadBack"] { print("xattr \(originalNameXattr) read back: \(rb)") }
    if let x = r["xattrRemoved"] { print("xattr removed: \(x)") }
}
