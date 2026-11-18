import AppKit
import Foundation

private struct TextLine {
    let text: String
    let font: NSFont
    let color: NSColor
}

/// Draws text lines top-down on a white canvas with a grey title bar and writes a PNG.
private func drawPNG(_ lines: [TextLine], title: String, size: CGSize, to url: URL) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw SpikeError("cannot create bitmap context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
    NSRect(x: 0, y: size.height - 56, width: size.width, height: 56).fill()
    NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.darkGray])
        .draw(at: NSPoint(x: 40, y: size.height - 42))

    var y = size.height - 110
    for line in lines {
        let s = NSAttributedString(string: line.text, attributes: [.font: line.font, .foregroundColor: line.color])
        y -= line.font.pointSize
        s.draw(at: NSPoint(x: 60, y: y))
        y -= line.font.pointSize * 0.9
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { throw SpikeError("PNG encoding failed") }
    try png.write(to: url)
}

private func tcFont(_ size: CGFloat, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "PingFangTC-Semibold" : "PingFangTC-Regular", size: size)
        ?? (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
}

private struct Fixture {
    let id: String
    let fileName: String
    let expectKeyword: String
    let title: String
    let lines: [TextLine]
}

private func fixtures() -> [Fixture] {
    let body = NSColor.black
    return [
        Fixture(id: "en-error-invoice", fileName: "Screenshot 2026-11-18 at 10.15.30.png", expectKeyword: "payment",
                title: "Acme Cloud Billing",
                lines: [
                    TextLine(text: "Payment Failed", font: .boldSystemFont(ofSize: 54), color: .systemRed),
                    TextLine(text: "Error 402: Your card ending in 4242 was declined.", font: .systemFont(ofSize: 30), color: body),
                    TextLine(text: "Invoice INV-20431 for Acme Cloud Hosting could not be paid.", font: .systemFont(ofSize: 30), color: body),
                    TextLine(text: "Amount due: $129.00   Due date: November 30, 2026", font: .systemFont(ofSize: 30), color: body),
                    TextLine(text: "Update payment method        Retry        Cancel", font: .systemFont(ofSize: 26), color: .systemBlue),
                ]),
        Fixture(id: "zh-hant-schedule", fileName: "Screenshot 2026-11-18 at 10.16.05.png", expectKeyword: "捷運",
                title: "台北捷運",
                lines: [
                    TextLine(text: "台北捷運時刻表", font: tcFont(56, bold: true), color: body),
                    TextLine(text: "淡水信義線　往象山方向", font: tcFont(34), color: body),
                    TextLine(text: "首班車 06:00　末班車 00:00", font: tcFont(32), color: body),
                    TextLine(text: "票價：新台幣 25 元　悠遊卡適用", font: tcFont(32), color: body),
                    TextLine(text: "請勿在車廂內飲食", font: tcFont(28), color: .darkGray),
                ]),
    ]
}

private struct Row {
    let test: String
    let step: String
    let status: String // PASS / FAIL / SKIP
    let ms: Double?
    let detail: String
}

func runSelfTest() async -> [String: Any] {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("NameSpike-selftest-\(UUID().uuidString.prefix(8))")
    var rows: [Row] = []
    var results: [[String: Any]] = []
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        return ["command": "selftest", "ok": false, "error": "cannot create temp dir: \(error)"]
    }
    print("Self-test directory (kept for inspection): \(dir.path)")
    let availability = modelAvailability()
    let modelAvailable = availability["available"] as? Bool == true
    print("Model available: \(modelAvailable)\(modelAvailable ? "" : ", reason: \(availability["reason"] ?? "unknown")")")

    for fx in fixtures() {
        var r: [String: Any] = ["fixture": fx.id]
        let url = dir.appendingPathComponent(fx.fileName)
        do {
            let t0 = nowNs()
            try drawPNG(fx.lines, title: fx.title, size: CGSize(width: 1400, height: 800), to: url)
            r["drawMs"] = ms(since: t0)
            r["image"] = url.path
        } catch {
            rows.append(Row(test: fx.id, step: "draw", status: "FAIL", ms: nil, detail: "\(error)"))
            r["drawError"] = "\(error)"
            results.append(r)
            continue
        }

        // OCR
        guard let ocr = try? runOCR(url) else {
            rows.append(Row(test: fx.id, step: "ocr", status: "FAIL", ms: nil, detail: "OCR threw"))
            results.append(r)
            continue
        }
        let joined = ocr.texts.joined(separator: " ")
        let ocrPass = !ocr.lines.isEmpty && joined.lowercased().contains(fx.expectKeyword)
        r["ocr"] = ocr.json
        r["ocrPass"] = ocrPass
        rows.append(Row(test: fx.id, step: "ocr", status: ocrPass ? "PASS" : "FAIL", ms: ocr.recognizeMs,
                        detail: "\(ocr.lines.count) lines, expects '\(fx.expectKeyword)'"))

        // Name, all lengths
        var modelName: String?
        var names: [String: Any] = [:]
        for length in NameLength.allCases {
            let n = await runNamer(ocrLines: ocr.texts, length: length)
            names[length.rawValue] = n
            let status: String
            if !modelAvailable { status = "SKIP" } else { status = (n["ok"] as? Bool == true) ? "PASS" : "FAIL" }
            let name = n["name"] as? String
            if length == .standard, status == "PASS" { modelName = name }
            let detail = name.map { "\($0) (words \(n["wordCount"] ?? 0), in range \(n["wordCountInRange"] ?? false))" }
                ?? "\(n["error"] ?? "no name")"
            rows.append(Row(test: fx.id, step: "name-\(length.rawValue)", status: status, ms: n["totalMs"] as? Double, detail: detail))
        }
        r["name"] = names

        // Fallback
        let fb = fallbackName(ocr: ocr, app: fx.id.hasPrefix("en") ? "Safari" : nil)
        let fbName = fb["name"] as? String ?? ""
        let fbPass = !fbName.isEmpty && fbName != "screenshot"
        r["fallback"] = fb
        r["fallbackPass"] = fbPass
        rows.append(Row(test: fx.id, step: "fallback", status: fbPass ? "PASS" : "FAIL", ms: fb["fallbackMs"] as? Double, detail: fbName))

        // Rename (with a planted collision so the -2 suffix path runs), then undo
        let newBase = modelName ?? fbName
        let collider = dir.appendingPathComponent(sanitizeFileName(newBase)).appendingPathExtension("png")
        fm.createFile(atPath: collider.path, contents: Data("collision".utf8))
        do {
            let t0 = nowNs()
            let rn = try renameKeepingDates(path: url.path, newBase: newBase)
            let rnMs = ms(since: t0)
            r["rename"] = rn
            let pass = rn["ok"] as? Bool == true && rn["collisionSuffix"] as? Bool == true
            rows.append(Row(test: fx.id, step: "rename", status: pass ? "PASS" : "FAIL", ms: rnMs,
                            detail: "\((rn["to"] as? String).map { ($0 as NSString).lastPathComponent } ?? "?") dates=\(rn["datesIdentical"] ?? false) xattr=\(rn["xattrMatchesOriginal"] ?? false) suffix=\(rn["collisionSuffix"] ?? false)"))
            if let to = rn["to"] as? String {
                let t1 = nowNs()
                let un = try undoRename(path: to)
                let unMs = ms(since: t1)
                r["undo"] = un
                let restoredOK = (un["to"] as? String) == url.path
                let upass = un["ok"] as? Bool == true && restoredOK
                rows.append(Row(test: fx.id, step: "undo", status: upass ? "PASS" : "FAIL", ms: unMs,
                                detail: "restored=\(restoredOK) dates=\(un["datesIdentical"] ?? false) xattrRemoved=\(un["xattrRemoved"] ?? false)"))
            }
        } catch {
            rows.append(Row(test: fx.id, step: "rename/undo", status: "FAIL", ms: nil, detail: "\(error)"))
            r["renameError"] = "\(error)"
        }
        results.append(r)
    }

    print("")
    print("test                step              status      ms  detail")
    print(String(repeating: "-", count: 100))
    for row in rows {
        let msText = row.ms.map { String(format: "%7.1f", $0) } ?? "      -"
        print(row.test.padding(toLength: 20, withPad: " ", startingAt: 0)
              + row.step.padding(toLength: 18, withPad: " ", startingAt: 0)
              + row.status.padding(toLength: 7, withPad: " ", startingAt: 0)
              + msText + "  " + row.detail)
    }
    let failed = rows.filter { $0.status == "FAIL" }.count
    let skipped = rows.filter { $0.status == "SKIP" }.count
    print("Result: \(rows.count - failed - skipped) pass, \(failed) fail, \(skipped) skip")

    return [
        "command": "selftest",
        "dir": dir.path,
        "model": availability,
        "ok": failed == 0,
        "failCount": failed,
        "skipCount": skipped,
        "rows": rows.map { ["test": $0.test, "step": $0.step, "status": $0.status, "ms": $0.ms as Any, "detail": $0.detail] },
        "results": results,
    ]
}
