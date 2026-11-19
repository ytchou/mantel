import NotchCore
import Testing
@testable import EventSources

@Test func aDragWithAPasteboardWriteStartsAndMouseUpEndsIt() {
    var machine = DragStateMachine()
    let down = machine.mouseDown(changeCount: 10)
    #expect(down == nil)
    let firstDrag = machine.dragged(changeCount: 10)
    #expect(firstDrag == nil)
    let written = machine.dragged(changeCount: 11)
    #expect(written == .started)
    let more = machine.dragged(changeCount: 11)
    #expect(more == nil)
    let up = machine.mouseUp()
    #expect(up == .ended)
    #expect(!machine.isActive)
    #expect(!machine.isArmed)
}

@Test func thePollCanSupplyThePasteboardChange() {
    var machine = DragStateMachine()
    _ = machine.mouseDown(changeCount: 3)
    let drag = machine.dragged(changeCount: 3)
    #expect(drag == nil)
    let polled = machine.polled(changeCount: 4)
    #expect(polled == .started)
}

@Test func thePasteboardChangeAloneDoesNotStartASession() {
    var machine = DragStateMachine()
    _ = machine.mouseDown(changeCount: 3)
    let polled = machine.polled(changeCount: 4)
    #expect(polled == nil)
    #expect(!machine.isActive)
    // The movement that follows completes the pair.
    let drag = machine.dragged(changeCount: 4)
    #expect(drag == .started)
}

@Test func aClickDragWithNoPasteboardWriteIsNotASession() {
    var machine = DragStateMachine()
    _ = machine.mouseDown(changeCount: 7)
    _ = machine.dragged(changeCount: 7)
    _ = machine.dragged(changeCount: 7)
    let up = machine.mouseUp()
    #expect(up == nil)
}

@Test func aPasteboardWriteBeforeMouseDownIsStale() {
    var machine = DragStateMachine()
    let early = machine.polled(changeCount: 5)
    #expect(early == nil)
    _ = machine.mouseDown(changeCount: 6)
    let drag = machine.dragged(changeCount: 6)
    #expect(drag == nil)
}

@Test func aDraggedEventWithoutMouseDownCannotStartOnItsOwn() {
    var machine = DragStateMachine()
    let drag = machine.dragged(changeCount: 9)
    #expect(drag == nil)
    #expect(machine.isArmed)
    let polled = machine.polled(changeCount: 10)
    #expect(polled == .started)
}

@Test func mouseUpTwiceEndsOnce() {
    var machine = DragStateMachine()
    _ = machine.mouseDown(changeCount: 0)
    _ = machine.dragged(changeCount: 1)
    let first = machine.mouseUp()
    let second = machine.mouseUp()
    #expect(first == .ended)
    #expect(second == nil)
}

@Test func aMouseDownDuringASessionEndsIt() {
    var machine = DragStateMachine()
    _ = machine.mouseDown(changeCount: 0)
    _ = machine.dragged(changeCount: 1)
    let down = machine.mouseDown(changeCount: 1)
    #expect(down == .ended)
    #expect(!machine.isActive)
}

@Test func pollingWhileUnarmedDoesNothing() {
    var machine = DragStateMachine()
    let polled = machine.polled(changeCount: 1)
    #expect(polled == nil)
    #expect(!machine.isArmed)
}

@Test func kindsComeFromEachItemsMostSpecificType() {
    let finderFile = ["public.file-url", "public.url", "public.utf8-plain-text"]
    let link = ["public.url", "public.utf8-plain-text"]
    let text = ["public.utf8-plain-text", "public.rtf"]
    let promise = ["com.apple.NSFilePromiseItemMetaData"]

    #expect(dragKinds(itemTypes: [finderFile]) == [.file])
    #expect(dragKinds(itemTypes: [link]) == [.link])
    #expect(dragKinds(itemTypes: [text]) == [.text])
    #expect(dragKinds(itemTypes: [promise]) == [.file])
    #expect(dragKinds(itemTypes: [finderFile, link, text]) == [.file, .link, .text])
    #expect(dragKinds(itemTypes: [["public.png"]]).isEmpty)
    #expect(dragKinds(itemTypes: []).isEmpty)
}
