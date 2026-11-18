import Foundation
import Vision
import ImageIO

struct OCRLine {
    let text: String
    let confidence: Float
    /// Vision normalized box, origin bottom-left.
    let box: CGRect
    let heightPx: Double
}

struct OCRResult {
    let lines: [OCRLine]
    let loadMs: Double
    let recognizeMs: Double
    let width: Int
    let height: Int
    let recognitionLanguages: [String]
    let zhHantSupported: Bool

    var texts: [String] { lines.map(\.text) }

    var json: [String: Any] {
        [
            "lines": texts,
            "lineCount": lines.count,
            "loadMs": loadMs,
            "recognizeMs": recognizeMs,
            "imageSize": [width, height],
            "recognitionLanguages": recognitionLanguages,
            "zhHantSupported": zhHantSupported,
            "automaticallyDetectsLanguage": true,
            "level": "accurate",
        ]
    }
}

func loadCGImage(_ url: URL) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw SpikeError("cannot load image at \(url.path)")
    }
    return img
}

func runOCR(_ url: URL) throws -> OCRResult {
    let t0 = nowNs()
    let image = try loadCGImage(url)
    let loadMs = ms(since: t0)

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    let supported = (try? request.supportedRecognitionLanguages()) ?? []
    // Order matters for Vision: Traditional Chinese first so mixed zh/en text is still read.
    let wanted = ["zh-Hant", "en-US"].filter { supported.contains($0) }
    if !wanted.isEmpty { request.recognitionLanguages = wanted }

    let t1 = nowNs()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    let recognizeMs = ms(since: t1)

    let observations = request.results ?? []
    let h = Double(image.height)
    let lines: [OCRLine] = observations.compactMap { obs in
        guard let top = obs.topCandidates(1).first else { return nil }
        return OCRLine(text: top.string, confidence: top.confidence, box: obs.boundingBox,
                       heightPx: Double(obs.boundingBox.height) * h)
    }
    // Top to bottom (larger maxY is higher on screen), then left to right.
    .sorted { a, b in
        if abs(a.box.maxY - b.box.maxY) > 0.01 { return a.box.maxY > b.box.maxY }
        return a.box.minX < b.box.minX
    }

    return OCRResult(lines: lines, loadMs: loadMs, recognizeMs: recognizeMs,
                     width: image.width, height: image.height,
                     recognitionLanguages: request.recognitionLanguages,
                     zhHantSupported: supported.contains("zh-Hant"))
}

func printOCR(_ r: OCRResult) {
    print("OCR: \(r.lines.count) lines, image \(r.width)x\(r.height), languages \(r.recognitionLanguages), zh-Hant supported: \(r.zhHantSupported)")
    for (i, l) in r.lines.enumerated() {
        print(String(format: "  %2d  h=%5.1fpx conf=%.2f  ", i + 1, l.heightPx, l.confidence) + l.text)
    }
    print("OCR load: \(r.loadMs) ms, recognize: \(r.recognizeMs) ms")
}
