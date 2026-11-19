import AppKit
import NotchCore
import Testing
@testable import NotchShell

// Made-up screens, far from any real display, so the panel these tests
// create is never visible.
private let builtInFrame = CGRect(x: 50_000, y: 0, width: 1512, height: 982)
private let builtIn = ScreenInfo(
    frame: builtInFrame,
    visibleFrame: CGRect(x: 50_000, y: 0, width: 1512, height: 950),
    // Whole points, so AppKit does not round the window frame.
    topLeft: CGRect(x: 0, y: 950, width: 664, height: 32),
    topRight: CGRect(x: 848, y: 950, width: 664, height: 32),
    safeTop: 32
)
private let external = ScreenInfo(
    frame: CGRect(x: 51_512, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 51_512, y: 0, width: 2560, height: 1415)
)

@Test func theNotchedScreenWinsWhereverItIsInTheList() {
    let first = NotchGeometry.choose(screens: [builtIn, external], main: external)
    let last = NotchGeometry.choose(screens: [external, builtIn], main: external)
    #expect(first?.isNotch == true)
    #expect(first == last)
    #expect(first?.anchorRect == CGRect(x: 50_664, y: 950, width: 184, height: 32))
}

@Test func withoutANotchedScreenTheMainScreenGetsAPill() {
    // Lid closed, external display only.
    let geometry = NotchGeometry.choose(screens: [external], main: external)
    #expect(geometry?.isNotch == false)
    #expect(geometry?.anchorRect.midX == external.frame.midX)
    // No main screen reported: the first screen is used.
    #expect(NotchGeometry.choose(screens: [external], main: nil) == geometry)
}

@Test func forcePillIgnoresTheNotch() {
    let geometry = NotchGeometry.choose(screens: [builtIn, external], main: builtIn, forcePill: true)
    #expect(geometry?.isNotch == false)
    #expect(geometry?.anchorRect.midX == builtIn.frame.midX)
}

@Test func noScreenGivesNoGeometry() {
    #expect(NotchGeometry.choose(screens: [], main: nil) == nil)
}

/// The screens a controller under test sees. Tests change `screens` and call
/// `screenChanged()`, as the system notification would.
@MainActor
private final class FakeScreens {
    var screens: [ScreenInfo]
    init(_ screens: [ScreenInfo]) { self.screens = screens }
    var geometry: NotchGeometry? { NotchGeometry.choose(screens: screens, main: screens.first) }
}

@MainActor
private func makeController(_ screens: FakeScreens) -> NotchShellController {
    _ = NSApplication.shared
    return NotchShellController(runtime: NotchRuntime(), geometryProvider: { screens.geometry })
}

@MainActor
@Test func thePanelFollowsTheNotchToAPillAndBack() {
    let screens = FakeScreens([builtIn, external])
    let shell = makeController(screens)
    shell.start()
    defer { shell.stop() }
    let notchFrame = shell.shownPanelFrame
    #expect(shell.geometry?.isNotch == true)
    #expect(notchFrame == screens.geometry?.panelFrame)

    // Lid closed: only the external display is left.
    screens.screens = [external]
    shell.screenChanged()
    #expect(shell.geometry?.isNotch == false)
    #expect(shell.shownPanelFrame == screens.geometry?.panelFrame)
    #expect(shell.shownPanelFrame != notchFrame)

    // Lid opened again.
    screens.screens = [builtIn, external]
    shell.screenChanged()
    #expect(shell.geometry?.isNotch == true)
    #expect(shell.shownPanelFrame == notchFrame)
}

@MainActor
@Test func thePanelHidesWithNoScreenAndReturnsWithOne() {
    let screens = FakeScreens([builtIn])
    let shell = makeController(screens)
    shell.start()
    defer { shell.stop() }
    #expect(shell.shownPanelFrame != nil)

    screens.screens = []
    shell.screenChanged()
    #expect(shell.shownPanelFrame == nil)

    screens.screens = [external]
    shell.screenChanged()
    #expect(shell.shownPanelFrame == screens.geometry?.panelFrame)
    #expect(shell.geometry?.isNotch == false)
}

@MainActor
@Test func startingWithNoScreenShowsThePanelWhenOneArrives() {
    let screens = FakeScreens([])
    let shell = makeController(screens)
    shell.start()
    defer { shell.stop() }
    #expect(shell.shownPanelFrame == nil)

    screens.screens = [builtIn]
    shell.screenChanged()
    #expect(shell.shownPanelFrame == screens.geometry?.panelFrame)
}

@MainActor
@Test func pollingIsFastOnlyOnOrNearTheShape() {
    let shape = CGRect(x: 664, y: 950, width: 184, height: 32)
    let fast = NotchShellController.fastInterval
    let slow = NotchShellController.slowInterval
    #expect(NotchShellController.pollInterval(pointer: CGPoint(x: 700, y: 960), shape: shape, isInside: false) == fast)
    // Just outside the shape, within the margin.
    #expect(NotchShellController.pollInterval(pointer: CGPoint(x: 620, y: 900), shape: shape, isInside: false) == fast)
    // Elsewhere, including under the large panel the shape lives in.
    #expect(NotchShellController.pollInterval(pointer: CGPoint(x: 700, y: 760), shape: shape, isInside: false) == slow)
    #expect(NotchShellController.pollInterval(pointer: CGPoint(x: 100, y: 100), shape: shape, isInside: false) == slow)
    // This app frontmost: mouse moves are not reported reliably, so the timer stays quicker.
    #expect(NotchShellController.pollInterval(pointer: CGPoint(x: 100, y: 100), shape: shape, isInside: false, appIsActive: true)
        == NotchShellController.activeAppInterval)
    // Held inside by hysteresis, wherever the pointer is.
    #expect(NotchShellController.pollInterval(pointer: CGPoint(x: 100, y: 100), shape: shape, isInside: true) == fast)
}
