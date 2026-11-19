import CoreGraphics
import Foundation
import NotchCore
import Testing
@testable import RenameBlock

private let titleLines = [
    RecognizedLine(text: "Payment Failed", box: CGRect(x: 0.1, y: 0.84, width: 0.5, height: 0.06)),
    RecognizedLine(text: "Your card was declined", box: CGRect(x: 0.1, y: 0.77, width: 0.5, height: 0.03)),
    RecognizedLine(text: "Contact support", box: CGRect(x: 0.1, y: 0.17, width: 0.5, height: 0.03)),
]

private let quickReader = FakeReader { _ in titleLines }

@MainActor
private func makeBlock(
    in folder: URL,
    reader: FakeReader = quickReader,
    namer: FakeNamer = FakeNamer { _ in "payment failed dialog" },
    timeLimit: Duration = .seconds(10)
) -> (RenameBlock, NotchRuntime) {
    let defaults = UserDefaults(suiteName: "RenameBlockTests-\(UUID().uuidString)")!
    let block = RenameBlock(
        reader: reader,
        namer: namer,
        timeLimit: timeLimit,
        defaults: defaults,
        recentsURL: folder.appending(path: "state/recents.json")
    )
    let runtime = NotchRuntime()
    runtime.register(block)
    return (block, runtime)
}

@MainActor
private func capture(_ url: URL, on runtime: NotchRuntime) {
    runtime.publish(ScreenshotCaptured(url: url, createdAt: Date()))
}

@MainActor
@Test func aCaptureShowsNamingInThePeekUntilDismissed() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let (block, runtime) = makeBlock(in: folder)

    capture(shot, on: runtime)

    #expect(runtime.state.owner == "rename")
    #expect(runtime.state.level == .peek)
    #expect(runtime.state.presentation?.duration == nil)
    #expect(runtime.state.presentation?.priority == .standard)
    #expect(block.model.phase == .naming)
    // A full peek that says which screenshot, not a mark beside the notch.
    #expect(runtime.state.presentation?.wing == nil)
    #expect(runtime.state.presentation?.peek != nil)
    #expect(block.model.currentName == "Screenshot 1.png")
    await waitUntil { block.current == nil }
}

@Test func namesReadAsWordsInTheNotchAndKeepTheirFileNames() {
    #expect(RenameDisplay.words("shelf-rename-panel-ears.png") == "Shelf Rename Panel Ears")
    #expect(RenameDisplay.words("2026-11-19-login_page.png") == "2026 11 19 Login Page")
    // One word, or a name macOS gave: shown as it is, without the extension.
    #expect(RenameDisplay.words("invoice.pdf") == "invoice")
    #expect(RenameDisplay.words("Screenshot 2026-11-19 at 6.45.56 PM.png") == "Screenshot 2026-11-19 at 6.45.56 PM")
    #expect(RenameDisplay.original("Screenshot 2026-11-19 at 6.45.56 PM.png") == "Screenshot 2026-11-19 at 6.45.56 PM")
}

@MainActor
@Test func aNamedScreenshotIsRenamedAndShownWithADuration() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let (block, runtime) = makeBlock(in: folder)

    capture(shot, on: runtime)
    await waitUntil { block.current == nil }

    let renamed = folder.appending(path: "payment-failed-dialog.png")
    #expect(exists(renamed))
    #expect(!exists(shot))
    #expect(runtime.state.owner == "rename")
    #expect(runtime.state.presentation?.duration == .seconds(6))
    #expect(block.model.recents.map(\.newName) == ["payment-failed-dialog.png"])
    #expect(block.model.recents.first?.usedFallback == false)
    #expect(exists(folder.appending(path: "state/recents.json")))
    guard case let .renamed(item) = block.model.phase else {
        Issue.record("expected the renamed phase, got \(block.model.phase)")
        return
    }
    #expect(item.originalName == "Screenshot 1.png")
}

@MainActor
@Test func undoInThePeekRestoresTheNameAndDismisses() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let (block, runtime) = makeBlock(in: folder)
    capture(shot, on: runtime)
    await waitUntil { block.current == nil }

    block.undoShown()

    #expect(exists(shot))
    #expect(!exists(folder.appending(path: "payment-failed-dialog.png")))
    #expect(runtime.state.owner == nil)
    #expect(block.model.recents.first?.reverted == true)

    // The watcher may report the restored file; it must not be renamed again.
    capture(shot, on: runtime)
    #expect(block.current == nil)
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func aModelTimeOutUsesTheFallbackName() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let slowNamer = FakeNamer { _ in
        try await Task.sleep(for: .seconds(10))
        return "too late"
    }
    let (block, runtime) = makeBlock(in: folder, namer: slowNamer, timeLimit: .milliseconds(50))

    capture(shot, on: runtime)
    await waitUntil { block.current == nil }

    #expect(exists(folder.appending(path: "screenshot-payment-failed.png")))
    #expect(block.model.recents.first?.usedFallback == true)
    #expect(runtime.state.presentation?.duration == .seconds(6))
}

@MainActor
@Test func anUnavailableModelUsesTheFallbackName() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let unavailable = FakeNamer(status: .appleIntelligenceNotEnabled) { _ in
        Issue.record("the namer must not be asked when the model is unavailable")
        return "never"
    }
    let (block, runtime) = makeBlock(in: folder, namer: unavailable)

    capture(shot, on: runtime)
    await waitUntil { block.current == nil }

    #expect(exists(folder.appending(path: "screenshot-payment-failed.png")))
    #expect(block.model.modelStatus == .appleIntelligenceNotEnabled)
}

@MainActor
@Test func aFileDeletedMidwayIsDroppedAndTheNotchReturnsToIdle() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let deletingReader = FakeReader { url in
        try FileManager.default.removeItem(at: url)
        return titleLines
    }
    let (block, runtime) = makeBlock(in: folder, reader: deletingReader)

    capture(shot, on: runtime)
    #expect(runtime.state.owner == "rename")
    await waitUntil { block.current == nil }

    #expect(runtime.state.owner == nil)
    #expect(block.model.phase == .idle)
    #expect(block.model.recents.isEmpty)
}

@MainActor
@Test func twoCapturesAreProcessedInOrder() async throws {
    let folder = try makeTempFolder()
    let first = try makeFile("alpha.png", in: folder)
    let second = try makeFile("beta.png", in: folder)
    let order = Recorder<String>()
    let reader = FakeReader { url in
        order.add(url.lastPathComponent)
        let word = url.deletingPathExtension().lastPathComponent
        return [RecognizedLine(text: word, box: CGRect(x: 0, y: 0.8, width: 0.5, height: 0.1))]
    }
    let namer = FakeNamer { request in "\(request.lines.first ?? "") renamed" }
    let (block, runtime) = makeBlock(in: folder, reader: reader, namer: namer)

    capture(first, on: runtime)
    capture(second, on: runtime)
    #expect(block.model.waiting == 1)

    await waitUntil { block.current == nil && block.model.recents.count == 2 }

    #expect(order.values == ["alpha.png", "beta.png"])
    #expect(exists(folder.appending(path: "alpha-renamed.png")))
    #expect(exists(folder.appending(path: "beta-renamed.png")))
    #expect(block.model.recents.map(\.newName) == ["beta-renamed.png", "alpha-renamed.png"])
    #expect(block.model.waiting == 0)
    #expect(runtime.state.presentation?.duration == .seconds(6))
}

@MainActor
@Test func theSameCaptureTwiceIsNamedOnce() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let (block, runtime) = makeBlock(in: folder)

    capture(shot, on: runtime)
    capture(shot, on: runtime)
    #expect(block.model.waiting == 0)
    await waitUntil { block.current == nil }

    #expect(block.model.recents.count == 1)
}

@MainActor
@Test func undoLastRenameIsOfferedOnceSomethingWasRenamed() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let (block, runtime) = makeBlock(in: folder)
    #expect(block.actions.first?.isEnabled == false)

    capture(shot, on: runtime)
    await waitUntil { block.current == nil }
    let action = try #require(block.actions.first)
    #expect(action.title == "Undo Last Rename")
    #expect(action.isEnabled)

    action.perform()

    #expect(exists(shot))
    #expect(block.actions.first?.isEnabled == false)
}
