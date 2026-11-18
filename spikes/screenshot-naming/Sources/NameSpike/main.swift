import Foundation

let usage = """
NameSpike - screenshot naming spike (throwaway)

  NameSpike watch [--seconds N]                         detect new screenshots (default 60 s)
  NameSpike ocr <image>                                 Vision OCR, lines top to bottom
  NameSpike name <image> [--length short|standard|detailed] [--image-input]
  NameSpike fallback <image> [--app <name>]             name without a language model
  NameSpike rename <file> <new-base-name>               rename, keep dates, store original name
  NameSpike undo <file>                                 restore the original name
  NameSpike selftest                                    generated images, all steps except watch

The last line of every command is one JSON object.
"""

let argv = Array(CommandLine.arguments.dropFirst())
let valuedOptions: Set<String> = ["--seconds", "--length", "--app"]

func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

let positional: [String] = {
    var out: [String] = []
    var i = 0
    while i < argv.count {
        let a = argv[i]
        if valuedOptions.contains(a) { i += 2; continue }
        if a.hasPrefix("--") { i += 1; continue }
        out.append(a)
        i += 1
    }
    return out
}()

func fail(_ command: String, _ message: String, code: Int32 = 1) -> Never {
    print("Error: \(message)")
    printJSON(["command": command, "ok": false, "error": message])
    exit(code)
}

func requireArg(_ command: String, _ index: Int, _ what: String) -> String {
    guard positional.count > index else { fail(command, "missing \(what)\n\n\(usage)", code: 2) }
    return positional[index]
}

let command = positional.first ?? ""

func runAsyncCommand() async -> Int32 {
    switch command {
    case "ocr":
        let path = requireArg(command, 1, "<image>")
        do {
            let r = try runOCR(URL(fileURLWithPath: path))
            printOCR(r)
            var j = r.json
            j["command"] = "ocr"; j["image"] = path; j["ok"] = true
            printJSON(j)
            return 0
        } catch { fail(command, "\(error)") }

    case "name":
        let path = requireArg(command, 1, "<image>")
        if argv.contains("--image-input") {
            // FoundationModels.swiftinterface (macOS SDK 26.2) has no image type: Prompt is built only
            // from PromptRepresentable (String, Prompt, Array, Generable content). No CGImage/NSImage/
            // image segment symbol exists, and Transcript.Segment has only .text and .structure.
            print("Image input is not available in FoundationModels on this SDK (macOS 26.2): no image symbol in the interface.")
            printJSON(["command": "name", "ok": false, "imageInputSupported": false,
                       "evidence": "Transcript.Segment cases: text, structure; PromptRepresentable conformers: String, Prompt, Array, ConvertibleToGeneratedContent; 0 matches for image|CGImage|NSImage in FoundationModels.swiftinterface"])
            return 2
        }
        let lengthText = option("--length") ?? "standard"
        guard let length = NameLength(rawValue: lengthText) else { fail(command, "unknown --length \(lengthText)", code: 2) }
        let total = nowNs()
        let ocr: OCRResult
        do { ocr = try runOCR(URL(fileURLWithPath: path)) } catch { fail(command, "\(error)") }
        print("OCR: \(ocr.lines.count) lines in \(ocr.recognizeMs) ms (load \(ocr.loadMs) ms)")
        var r = await runNamer(ocrLines: ocr.texts, length: length)
        printNamer(r)
        let totalMs = ms(since: total)
        print("Total (OCR + model): \(totalMs) ms")
        r["command"] = "name"; r["image"] = path
        r["ocrMs"] = ocr.recognizeMs; r["ocrLoadMs"] = ocr.loadMs; r["ocrLineCount"] = ocr.lines.count
        r["endToEndMs"] = totalMs
        printJSON(r)
        return (r["ok"] as? Bool == true) ? 0 : 1

    case "fallback":
        let path = requireArg(command, 1, "<image>")
        let ocr: OCRResult
        do { ocr = try runOCR(URL(fileURLWithPath: path)) } catch { fail(command, "\(error)") }
        var r = fallbackName(ocr: ocr, app: option("--app"))
        print("OCR: \(ocr.lines.count) lines in \(ocr.recognizeMs) ms")
        print("Picked lines: \(r["pickedLines"] ?? [])  heights px: \(r["pickedHeightsPx"] ?? [])")
        print("Fallback name: \(r["name"] ?? "")  (\(r["fallbackMs"] ?? 0) ms after OCR)")
        r["command"] = "fallback"; r["image"] = path; r["ocrMs"] = ocr.recognizeMs; r["ok"] = true
        printJSON(r)
        return 0

    case "rename":
        let path = requireArg(command, 1, "<file>")
        let base = requireArg(command, 2, "<new-base-name>")
        do {
            var r = try renameKeepingDates(path: path, newBase: base)
            printRename(r)
            r["command"] = "rename"
            printJSON(r)
            return (r["ok"] as? Bool == true) ? 0 : 1
        } catch { fail(command, "\(error)") }

    case "undo":
        let path = requireArg(command, 1, "<file>")
        do {
            var r = try undoRename(path: path)
            printRename(r)
            r["command"] = "undo"
            printJSON(r)
            return (r["ok"] as? Bool == true) ? 0 : 1
        } catch { fail(command, "\(error)") }

    case "selftest":
        let r = await runSelfTest()
        printJSON(r)
        return (r["ok"] as? Bool == true) ? 0 : 1

    default:
        print(usage)
        printJSON(["command": command, "ok": false, "error": "unknown command"])
        return 2
    }
}

if command == "watch" {
    // Synchronous: NSMetadataQuery needs the main run loop, which ScreenshotWatcher runs itself.
    let seconds = option("--seconds").flatMap(Double.init) ?? 60
    let (folder, source) = screenshotFolder()
    print("Screenshot folder: \(folder.path) (from \(source))")
    var r = ScreenshotWatcher(folder: folder, seconds: seconds).run()
    r["folderSource"] = source
    printJSON(r)
    exit(0)
}

Task {
    let code = await runAsyncCommand()
    exit(code)
}
dispatchMain()
