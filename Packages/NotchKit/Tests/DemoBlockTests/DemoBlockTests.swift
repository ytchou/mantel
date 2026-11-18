import Foundation
import NotchCore
import Testing
@testable import DemoBlock

@MainActor
@Test func hoverShowsTheClockAndLeavingRemovesIt() {
    let runtime = NotchRuntime()
    runtime.register(DemoBlock())
    #expect(runtime.state.owner == nil)

    runtime.pointerHoverChanged(isInside: true)
    #expect(runtime.state.owner == "demo")
    #expect(runtime.state.level == .expanded)

    runtime.pointerHoverChanged(isInside: false)
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func aDisabledBlockDoesNotReactToHover() {
    let runtime = NotchRuntime()
    runtime.register(DemoBlock(), enabled: false)
    runtime.pointerHoverChanged(isInside: true)
    #expect(runtime.state.owner == nil)
}

@MainActor
@Test func aClickTogglesTheSecondsAndADropIsNamed() {
    let runtime = NotchRuntime()
    let block = DemoBlock()
    runtime.register(block)
    runtime.pointerHoverChanged(isInside: true)

    runtime.send(.click)
    #expect(block.model.showsSeconds == false)

    runtime.send(.drop([.file(URL(filePath: "/tmp/a.png")), .text("hello")]))
    #expect(block.model.lastDrop == "a.png + 1 more")
}

@MainActor
@Test func inputIsIgnoredWhileTheBlockDoesNotOwnTheNotch() {
    let runtime = NotchRuntime()
    let block = DemoBlock()
    runtime.register(block)

    runtime.send(.click)
    #expect(block.model.showsSeconds == true)
}
