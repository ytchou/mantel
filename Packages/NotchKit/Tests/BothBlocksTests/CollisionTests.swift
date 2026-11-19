import Foundation
import Testing
@testable import NotchCore
@testable import RenameBlock
@testable import ShelfBlock

// What happens when the shelf and the rename block want the notch at once.
// Each test registers both blocks in one runtime, as the app does.

@MainActor
@Test func aScreenshotDuringADragWaitsBehindTheDropTarget() async throws {
    let f = try Fixture(gateOpen: false)
    let shot = try makeScreenshot("Screenshot 1.png", in: f.folder)

    f.runtime.publish(DragSessionStarted(kinds: [.file]))
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    // The screenshot lands mid-drag: the drop target must stay up.
    f.capture(shot)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)
    #expect(f.shelf.store.itemCount == 1)

    f.gate.open()
    await waitUntil { !f.rename.model.recents.isEmpty }
    // Named while the drag is still on: still the drop target.
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.shelfFileNames == ["payment-failed-dialog.png"])

    // The drag ends elsewhere: the rename result gets its turn, with its full time.
    f.runtime.publish(DragSessionEnded())
    #expect(f.runtime.state.owner == "rename")
    #expect(f.runtime.state.presentation?.duration == RenameBlock.resultDuration)
}

@MainActor
@Test func theShelfReturnsAfterARenameResult() async throws {
    let f = try Fixture()
    f.runtime.publish(DragSessionStarted(kinds: [.text]))
    f.runtime.send(.drop([.text("held")]))
    f.runtime.publish(DragSessionEnded())
    #expect(f.runtime.state.owner == "shelf")

    f.capture(try makeScreenshot("Screenshot 1.png", in: f.folder))
    await waitUntil { if case .renamed = f.rename.model.phase { true } else { false } }
    #expect(f.runtime.state.owner == "rename")
    #expect(f.runtime.state.level == .peek)

    // The result's time runs out: the shelf, now holding the screenshot too, is back.
    await waitUntil { f.clock.sleeperCount > 0 }
    f.clock.advance(by: RenameBlock.resultDuration)
    await waitUntil { f.runtime.state.owner == "shelf" }
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .peek)
    #expect(f.shelf.store.itemCount == 2)
}

@MainActor
@Test func aScreenshotDoesNotTakeTheNotchFromAShelfInUse() async throws {
    let f = try Fixture()
    f.runtime.publish(DragSessionStarted(kinds: [.text]))
    f.runtime.send(.drop([.text("held")]))
    f.runtime.publish(DragSessionEnded())

    // The pointer is on the open shelf.
    f.runtime.pointerHoverChanged(isInside: true)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    f.capture(try makeScreenshot("Screenshot 1.png", in: f.folder))
    #expect(f.runtime.state.owner == "shelf")
    await waitUntil { if case .renamed = f.rename.model.phase { true } else { false } }
    // Still the shelf, still open, and the new screenshot is on it.
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)
    #expect(f.shelf.store.itemCount == 2)

    // The pointer leaves: the rename result is shown, then the shelf returns.
    f.runtime.pointerHoverChanged(isInside: false)
    #expect(f.runtime.state.owner == "rename")
    await waitUntil { f.clock.sleeperCount > 0 }
    f.clock.advance(by: RenameBlock.resultDuration)
    await waitUntil { f.runtime.state.owner == "shelf" }
    #expect(f.runtime.state.owner == "shelf")
}

@MainActor
@Test func hoveringARenameResultDoesNotLetTheShelfTakeIt() async throws {
    let f = try Fixture()
    f.runtime.publish(DragSessionStarted(kinds: [.text]))
    f.runtime.send(.drop([.text("held")]))
    f.runtime.publish(DragSessionEnded())

    f.capture(try makeScreenshot("Screenshot 1.png", in: f.folder))
    await waitUntil { if case .renamed = f.rename.model.phase { true } else { false } }
    #expect(f.runtime.state.owner == "rename")

    // The pointer goes to the result, for Undo: it must stay the rename block's.
    f.runtime.pointerHoverChanged(isInside: true)
    #expect(f.runtime.state.owner == "rename")
}

@MainActor
@Test func aBurstOfScreenshotsIsAllCollectedAndAllRenamed() async throws {
    let f = try Fixture(gateOpen: false)
    let shots = try (1...5).map { try makeScreenshot("Screenshot \($0).png", in: f.folder) }

    shots.forEach { f.capture($0) }
    #expect(f.shelf.store.itemCount == 5)
    #expect(f.rename.model.waiting == 4)
    #expect(f.runtime.state.owner == "rename")

    f.gate.open()
    await waitUntil { f.rename.model.recents.count == 5 }
    #expect(f.rename.model.recents.count == 5)
    // Every shelf item followed its file to a new, distinct name.
    let names = f.shelfFileNames
    #expect(names.count == 5)
    #expect(Set(names).count == 5)
    #expect(names.allSatisfy { $0.hasPrefix("payment-failed-dialog") })
    // One result is shown, for the last one.
    #expect(f.runtime.state.owner == "rename")
    #expect(f.rename.model.waiting == 0)
}

@MainActor
@Test func turningOffTheOwnerHandsTheNotchToTheOtherBlock() async throws {
    let f = try Fixture(gateOpen: false)
    f.runtime.publish(DragSessionStarted(kinds: [.text]))
    f.runtime.send(.drop([.text("held")]))
    f.runtime.publish(DragSessionEnded())
    let shot = try makeScreenshot("Screenshot 1.png", in: f.folder)
    f.capture(shot)
    #expect(f.runtime.state.owner == "rename")

    // Rename is turned off mid-job: the shelf shows, and the file keeps its name.
    f.runtime.setEnabled("rename", false)
    #expect(f.runtime.state.owner == "shelf")
    f.gate.open()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(FileManager.default.fileExists(atPath: shot.path))
    #expect(f.rename.model.recents.isEmpty)
    #expect(f.runtime.state.owner == "shelf")

    // The shelf is turned off while it owns the notch, mid-drag: nothing is left on screen.
    f.runtime.publish(DragSessionStarted(kinds: [.file]))
    #expect(f.runtime.state.owner == "shelf")
    f.runtime.setEnabled("shelf", false)
    #expect(f.runtime.state.owner == nil)
    f.runtime.publish(DragSessionEnded())
    #expect(f.runtime.state.owner == nil)

    // Both back on: the shelf still holds its items; a new screenshot is named.
    f.runtime.setEnabled("shelf", true)
    f.runtime.setEnabled("rename", true)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.shelf.store.itemCount == 2)
    f.capture(try makeScreenshot("Screenshot 2.png", in: f.folder))
    await waitUntil { !f.rename.model.recents.isEmpty }
    #expect(f.rename.model.recents.count == 1)
}
