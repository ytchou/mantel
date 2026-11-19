import Foundation
import NotchCore
import Testing
@testable import ShelfBlock

@MainActor
private func makeShelf(lateDropGrace: Duration = .seconds(60)) throws -> (NotchRuntime, ShelfBlock) {
    let runtime = NotchRuntime()
    let block = ShelfBlock(directory: try makeTemporaryDirectory(), lateDropGrace: lateDropGrace)
    runtime.register(block)
    return (runtime, block)
}

/// Run one external drag that drops `items` on the notch.
@MainActor
private func dragAndDrop(_ items: [DroppedItem], on runtime: NotchRuntime) {
    runtime.publish(DragSessionStarted(kinds: Set(items.map(\.kind))))
    runtime.send(.drop(items))
    runtime.publish(DragSessionEnded())
}

/// Let tasks run until `condition` holds or about a second passes.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
@Test func anEmptyShelfShowsNothing() throws {
    let (runtime, _) = try makeShelf()
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func aDragOpensTheShelfExpandedAsADropTarget() throws {
    let (runtime, block) = try makeShelf()
    runtime.publish(DragSessionStarted(kinds: [.file]))

    #expect(runtime.state.owner == "shelf")
    #expect(runtime.state.level == .expanded)
    #expect(runtime.state.presentation?.priority == .interactive)
    #expect(runtime.state.presentation?.accepts == [.file, .link, .text])
    #expect(runtime.state.presentation?.duration == nil)
    #expect(block.ui.isDropTarget)
}

@MainActor
@Test func aDropAddsTheItemsAsOneStack() throws {
    let (runtime, block) = try makeShelf()
    runtime.publish(DragSessionStarted(kinds: [.text, .link]))
    runtime.send(.drop([.text("hello"), .link(exampleLink)]))

    #expect(block.store.stacks.count == 1)
    #expect(block.store.itemCount == 2)
    // Still the drop target until the drag ends.
    #expect(runtime.state.level == .expanded)
}

@MainActor
@Test func aDragEndingWithItemsHeldFallsBackToTheCountPeek() throws {
    let (runtime, block) = try makeShelf()
    dragAndDrop([.text("a"), .text("b"), .link(exampleLink)], on: runtime)

    #expect(runtime.state.owner == "shelf")
    #expect(runtime.state.level == .peek)
    #expect(runtime.state.presentation?.priority == .ambient)
    #expect(runtime.state.presentation?.wing != nil)
    #expect(runtime.state.presentation?.expanded != nil)
    #expect(runtime.state.presentation?.duration == nil)
    #expect(block.store.itemCount == 3)
    #expect(!block.ui.isDropTarget)

    // Hovering the peek expands it.
    runtime.pointerHoverChanged(isInside: true)
    #expect(runtime.state.level == .expanded)
}

@MainActor
@Test func aDragEndingWithNothingHeldDismisses() throws {
    let (runtime, _) = try makeShelf()
    runtime.publish(DragSessionStarted(kinds: [.file]))
    runtime.publish(DragSessionEnded())
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func aLateDropAfterReleaseOverTheNotchIsStillAdded() throws {
    let (runtime, block) = try makeShelf()
    runtime.publish(DragSessionStarted(kinds: [.file]))
    runtime.pointerHoverChanged(isInside: true)
    runtime.publish(DragSessionEnded())

    // Waiting for promised files: still owns the notch and takes drops.
    #expect(runtime.state.owner == "shelf")
    #expect(runtime.state.presentation?.accepts.contains(.file) == true)
    #expect(block.ui.isReceiving)

    runtime.send(.drop([.text("late")]))
    #expect(block.store.itemCount == 1)
    #expect(!block.ui.isReceiving)
    // The pointer is still on the shelf, so it keeps the notch; at rest it is ambient.
    #expect(runtime.state.presentation?.priority == .interactive)
    runtime.pointerHoverChanged(isInside: false)
    #expect(runtime.state.presentation?.priority == .ambient)
}

@MainActor
@Test func theLateDropWaitEndsAfterTheGracePeriod() async throws {
    let (runtime, block) = try makeShelf(lateDropGrace: .milliseconds(20))
    runtime.publish(DragSessionStarted(kinds: [.file]))
    runtime.pointerHoverChanged(isInside: true)
    runtime.publish(DragSessionEnded())
    #expect(runtime.state.owner == "shelf")

    await waitUntil { runtime.state.owner == nil }
    #expect(runtime.state.owner == nil)
    #expect(!block.ui.isReceiving)
}

@MainActor
@Test func noLateDropWaitWhenReleasedAwayFromTheNotch() throws {
    let (runtime, _) = try makeShelf()
    runtime.publish(DragSessionStarted(kinds: [.file]))
    runtime.publish(DragSessionEnded())
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func aSuccessfulDragOutTakesTheStackOffTheShelf() throws {
    let (runtime, block) = try makeShelf()
    dragAndDrop([.text("a"), .text("b")], on: runtime)
    dragAndDrop([.text("keep")], on: runtime)
    let leaving = try #require(block.store.stacks.last)

    _ = block.beginDragOut(.stack(leaving.id))
    // The monitor reports the shelf's own drag as a session too.
    runtime.publish(DragSessionStarted(kinds: [.text]))
    #expect(runtime.state.owner == "shelf")
    #expect(runtime.state.level == .expanded)
    #expect(runtime.state.presentation?.accepts.isEmpty == true)
    #expect(!block.ui.isDropTarget)

    // Stays expanded with the pointer outside the notch.
    runtime.pointerHoverChanged(isInside: true)
    runtime.pointerHoverChanged(isInside: false)
    #expect(runtime.state.level == .expanded)

    block.endDragOut(.stack(leaving.id), succeeded: true)
    runtime.publish(DragSessionEnded())

    #expect(block.store.itemCount == 1)
    #expect(block.store.stack(leaving.id) == nil)
    #expect(runtime.state.level == .peek)
}

@MainActor
@Test func aSuccessfulDragOutOfOneItemLeavesTheRestOfTheStack() throws {
    let (runtime, block) = try makeShelf()
    dragAndDrop([.text("a"), .text("b")], on: runtime)
    let item = try #require(block.store.stacks.first?.items.first)

    _ = block.beginDragOut(.item(item.id))
    block.endDragOut(.item(item.id), succeeded: true)

    #expect(block.store.itemCount == 1)
}

@MainActor
@Test func aCancelledDragOutKeepsTheItems() throws {
    let (runtime, block) = try makeShelf()
    dragAndDrop([.text("a")], on: runtime)
    let stack = try #require(block.store.stacks.first)

    _ = block.beginDragOut(.stack(stack.id))
    runtime.publish(DragSessionStarted(kinds: [.text]))
    runtime.publish(DragSessionEnded())
    block.endDragOut(.stack(stack.id), succeeded: false)

    #expect(block.store.itemCount == 1)
    #expect(runtime.state.presentation?.priority == .ambient)
}

@MainActor
@Test func draggingOutTheLastItemEmptiesTheNotch() throws {
    let (runtime, block) = try makeShelf()
    dragAndDrop([.text("a")], on: runtime)
    let stack = try #require(block.store.stacks.first)

    _ = block.beginDragOut(.stack(stack.id))
    block.endDragOut(.stack(stack.id), succeeded: true)
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func clearShelfActionEmptiesItAndDismisses() throws {
    let (runtime, block) = try makeShelf()
    dragAndDrop([.text("a"), .link(exampleLink)], on: runtime)

    let clear = try #require(block.actions.first { $0.id == "shelf.clear" })
    #expect(clear.isEnabled)
    clear.perform()

    #expect(block.store.isEmpty)
    #expect(runtime.state.owner == nil)
    let afterClear = try #require(block.actions.first)
    #expect(!afterClear.isEnabled)
}

@MainActor
@Test func removingTheLastItemFromTheViewDismisses() throws {
    let (runtime, block) = try makeShelf()
    dragAndDrop([.text("a")], on: runtime)
    let stack = try #require(block.store.stacks.first)

    block.remove(.stack(stack.id))
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func heldItemsShowTheirPeekAfterARelaunch() throws {
    let directory = try makeTemporaryDirectory()
    let first = NotchRuntime()
    let shelf = ShelfBlock(directory: directory)
    first.register(shelf)
    dragAndDrop([.text("a"), .text("b")], on: first)

    let runtime = NotchRuntime()
    runtime.register(ShelfBlock(directory: directory))
    #expect(runtime.state.owner == "shelf")
    #expect(runtime.state.level == .peek)
}

@MainActor
@Test func aDisabledShelfIgnoresDrags() throws {
    let runtime = NotchRuntime()
    runtime.register(ShelfBlock(directory: try makeTemporaryDirectory()), enabled: false)
    runtime.publish(DragSessionStarted(kinds: [.file]))
    #expect(runtime.state.owner == nil)
}

/// A fresh defaults suite, so tests never read the user's own settings.
private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "ShelfBlockTests.\(UUID().uuidString)")!
}

@MainActor
@Test func aNewScreenshotIsAddedAndFollowsARename() throws {
    let runtime = NotchRuntime()
    let block = ShelfBlock(directory: try makeTemporaryDirectory(), defaults: makeDefaults())
    runtime.register(block)
    let folder = try makeTemporaryDirectory()
    let shot = try makeFile(named: "Screenshot 1.png", in: folder)

    runtime.publish(ScreenshotCaptured(url: shot, createdAt: Date()))
    #expect(block.store.itemCount == 1)
    #expect(runtime.state.owner == "shelf")
    let item = try #require(block.store.stacks.first?.items.first)
    #expect(item.isOwnedFile == false)

    // What the rename block does: a move inside the same folder.
    let renamed = folder.appending(path: "Login page.png")
    try FileManager.default.moveItem(at: shot, to: renamed)
    #expect(block.store.fileURL(of: item)?.lastPathComponent == "Login page.png")

    // Removing the item leaves the user's file alone.
    block.remove(.item(item.id))
    #expect(block.store.isEmpty)
    #expect(FileManager.default.fileExists(atPath: renamed.path(percentEncoded: false)))
}

@MainActor
@Test func screenshotsAreNotAddedWhenTheSettingIsOff() throws {
    let defaults = makeDefaults()
    defaults.set("NO", forKey: ShelfSettings.collectScreenshotsKey)
    let runtime = NotchRuntime()
    let block = ShelfBlock(directory: try makeTemporaryDirectory(), defaults: defaults)
    runtime.register(block)
    let shot = try makeFile(named: "Screenshot 2.png", in: try makeTemporaryDirectory())

    runtime.publish(ScreenshotCaptured(url: shot, createdAt: Date()))
    #expect(block.store.isEmpty)
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func atRestTheShelfTakesNoRoomUnlessTheCountIsTurnedOn() throws {
    let runtime = NotchRuntime()
    let block = ShelfBlock(directory: try makeTemporaryDirectory(), defaults: makeDefaults())
    runtime.register(block)
    dragAndDrop([.text("hello")], on: runtime)

    // Holding an item: it owns the notch at the peek level, with a wing of no width.
    #expect(runtime.state.owner == "shelf")
    #expect(runtime.state.level == .peek)
    #expect(runtime.state.presentation?.wing?.size.width == 0)
    #expect(runtime.state.presentation?.peek == nil)

    block.settings.showCount = true
    #expect(runtime.state.presentation?.wing?.size.width == ShelfBlock.wingSize.width)

    // Hovering opens the shelf either way.
    block.settings.showCount = false
    runtime.pointerHoverChanged(isInside: true)
    #expect(runtime.state.level == .expanded)
}
