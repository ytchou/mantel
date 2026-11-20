import Foundation
import Testing
@testable import NotchCore

// What happens when the shelf and the rename block want the notch at once.
// All three blocks run in one runtime as stand-ins, as in the app; each
// block process is played by a script (see `TestSupport.swift`).

@MainActor
@Test func aScreenshotDuringADragWaitsBehindTheDropTarget() async throws {
    let f = try Fixture(gateOpen: false)
    let shot = try makeScreenshot("Screenshot 1.png", in: f.folder)

    await f.publish(DragSessionStarted(kinds: [.file]))
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    // The screenshot lands mid-drag: the drop target must stay up.
    await f.capture(shot)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)
    #expect(f.shelf.itemCount == 1)

    f.gate.open()
    await f.waitFor { !f.rename.recents.isEmpty }
    // Named while the drag is still on: still the drop target.
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.screenshotNames == ["payment-failed-dialog.png"])

    // The drag ends elsewhere: the rename result gets its turn, with its full time.
    await f.publish(DragSessionEnded())
    #expect(f.runtime.state.owner == "rename")
    #expect(f.runtime.state.presentation?.duration == ScriptedRename.resultDuration)
}

@MainActor
@Test func theShelfReturnsAfterARenameResult() async throws {
    let f = try Fixture()
    await f.publish(DragSessionStarted(kinds: [.text]))
    await f.drop([.text("held")])
    await f.publish(DragSessionEnded())
    #expect(f.runtime.state.owner == "shelf")

    await f.capture(try makeScreenshot("Screenshot 1.png", in: f.folder))
    await f.waitFor { if case .renamed = f.rename.phase { true } else { false } }
    #expect(f.runtime.state.owner == "rename")
    #expect(f.runtime.state.level == .peek)

    // The result's time runs out: the shelf, now holding the screenshot too, is back.
    await waitUntil { f.clock.sleeperCount > 0 }
    f.clock.advance(by: ScriptedRename.resultDuration)
    await waitUntil { f.runtime.state.owner == "shelf" }
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .peek)
    #expect(f.shelf.itemCount == 2)
}

@MainActor
@Test func aScreenshotDoesNotTakeTheNotchFromAShelfInUse() async throws {
    let f = try Fixture()
    await f.publish(DragSessionStarted(kinds: [.text]))
    await f.drop([.text("held")])
    await f.publish(DragSessionEnded())

    // The pointer is on the open shelf.
    await f.hover(true)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    await f.capture(try makeScreenshot("Screenshot 1.png", in: f.folder))
    #expect(f.runtime.state.owner == "shelf")
    await f.waitFor { if case .renamed = f.rename.phase { true } else { false } }
    // Still the shelf, still open, and the new screenshot is on it.
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)
    #expect(f.shelf.itemCount == 2)

    // The pointer leaves: the rename result is shown, then the shelf returns.
    await f.hover(false)
    #expect(f.runtime.state.owner == "rename")
    await waitUntil { f.clock.sleeperCount > 0 }
    f.clock.advance(by: ScriptedRename.resultDuration)
    await waitUntil { f.runtime.state.owner == "shelf" }
    #expect(f.runtime.state.owner == "shelf")
}

@MainActor
@Test func hoveringARenameResultDoesNotLetTheShelfTakeIt() async throws {
    let f = try Fixture()
    await f.publish(DragSessionStarted(kinds: [.text]))
    await f.drop([.text("held")])
    await f.publish(DragSessionEnded())

    await f.capture(try makeScreenshot("Screenshot 1.png", in: f.folder))
    await f.waitFor { if case .renamed = f.rename.phase { true } else { false } }
    #expect(f.runtime.state.owner == "rename")

    // The pointer goes to the result, for Undo: it must stay the rename block's.
    await f.hover(true)
    #expect(f.runtime.state.owner == "rename")
}

@MainActor
@Test func aBurstOfScreenshotsIsAllCollectedAndAllRenamed() async throws {
    let f = try Fixture(gateOpen: false)
    let shots = try (1...5).map { try makeScreenshot("Screenshot \($0).png", in: f.folder) }

    for shot in shots { await f.capture(shot) }
    #expect(f.shelf.itemCount == 5)
    #expect(f.rename.waiting == 4)
    #expect(f.runtime.state.owner == "rename")

    f.gate.open()
    await f.waitFor { f.rename.recents.count == 5 }
    #expect(f.rename.recents.count == 5)
    // Every screenshot has a new, distinct name.
    let names = f.screenshotNames
    #expect(names.count == 5)
    #expect(Set(names).count == 5)
    #expect(names.allSatisfy { $0.hasPrefix("payment-failed-dialog") })
    // One result is shown, for the last one.
    #expect(f.runtime.state.owner == "rename")
    #expect(f.rename.waiting == 0)
}

@MainActor
@Test func turningOffTheOwnerHandsTheNotchToTheOtherBlock() async throws {
    let f = try Fixture(gateOpen: false)
    await f.publish(DragSessionStarted(kinds: [.text]))
    await f.drop([.text("held")])
    await f.publish(DragSessionEnded())
    let shot = try makeScreenshot("Screenshot 1.png", in: f.folder)
    await f.capture(shot)
    #expect(f.runtime.state.owner == "rename")

    // Rename is turned off mid-job: the shelf shows, and the file keeps its name.
    await f.setEnabled("rename", false)
    #expect(f.runtime.state.owner == "shelf")
    f.gate.open()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(FileManager.default.fileExists(atPath: shot.path))
    #expect(f.rename.recents.isEmpty)
    #expect(f.runtime.state.owner == "shelf")

    // The shelf is turned off while it owns the notch, mid-drag: nothing is left on screen.
    await f.publish(DragSessionStarted(kinds: [.file]))
    #expect(f.runtime.state.owner == "shelf")
    await f.setEnabled("shelf", false)
    #expect(f.runtime.state.owner == nil)
    await f.publish(DragSessionEnded())
    #expect(f.runtime.state.owner == nil)

    // Both back on: the shelf still holds its items; a new screenshot is named.
    await f.setEnabled("shelf", true)
    await f.setEnabled("rename", true)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.shelf.itemCount == 2)
    await f.capture(try makeScreenshot("Screenshot 2.png", in: f.folder))
    await f.waitFor { !f.rename.recents.isEmpty }
    #expect(f.rename.recents.count == 1)
}
