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
