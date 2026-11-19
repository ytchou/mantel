import CoreGraphics
import NotchCore
import Testing
@testable import NotchShell

// A 1512x982 screen with a 185x32 notch centred at the top.
private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
private let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)
private let notched = NotchGeometry(screenFrame: screen, visibleFrame: visible, notch: notch)
private let pill = NotchGeometry(screenFrame: screen, visibleFrame: visible, notch: nil)

private func expectCentredAndHanging(_ rect: CGRect, from anchor: CGRect) {
    #expect(abs(rect.midX - anchor.midX) < 0.001)
    #expect(rect.maxY == anchor.maxY)
}

@Test func notchRectComesFromAuxiliaryAreasAndSafeTop() {
    let rect = NotchGeometry.notchRect(
        screenFrame: CGRect(x: 100, y: 0, width: 1512, height: 982),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)
    #expect(rect == CGRect(x: 763.5, y: 950, width: 185, height: 32))
}

@Test func noNotchWithoutAuxiliaryAreasOrInset() {
    #expect(NotchGeometry.notchRect(screenFrame: screen, topLeft: nil, topRight: nil, safeTop: 32) == nil)
    #expect(NotchGeometry.notchRect(screenFrame: screen, topLeft: .zero, topRight: .zero, safeTop: 0) == nil)
}

@Test func idleShapeCoversTheNotch() {
    #expect(notched.isNotch)
    #expect(notched.shapeRect(level: nil, contentSize: .zero) == notch)
}

@Test func pillSitsCentredUnderTheMenuBar() {
    #expect(!pill.isNotch)
    let idle = pill.shapeRect(level: nil, contentSize: .zero)
    #expect(idle.size == NotchGeometry.pillSize)
    #expect(idle.midX == screen.midX)
    #expect(idle.maxY == visible.maxY - NotchGeometry.pillGap)
}

@Test func peekKeepsTheNotchAndGrowsDownByContentHeight() {
    let rect = notched.shapeRect(level: .peek, contentSize: CGSize(width: 300, height: 30))
    #expect(rect.size == CGSize(width: 300, height: notch.height + 30))
    expectCentredAndHanging(rect, from: notch)
}

@Test func peekIsAtLeastNotchWidth() {
    let rect = notched.shapeRect(level: .peek, contentSize: CGSize(width: 50, height: 20))
    #expect(rect.width == notch.width)
}

@Test func peekIsClampedToLimits() {
    let rect = notched.shapeRect(level: .peek, contentSize: CGSize(width: 2000, height: 2000))
    #expect(rect.width == NotchLimits.maxPeekSize.width)
    #expect(rect.height == notch.height + NotchLimits.maxPeekSize.height)
}

@Test func expandedIsClampedAndBelowTheNotchHeight() {
    let rect = notched.shapeRect(level: .expanded, contentSize: CGSize(width: 2000, height: 2000))
    #expect(rect.width == NotchLimits.maxExpandedSize.width)
    #expect(rect.height == notch.height + NotchLimits.maxExpandedSize.height)
    expectCentredAndHanging(rect, from: notch)
}

@Test func pillGrowsTheSameWay() {
    let anchor = pill.shapeRect(level: nil, contentSize: .zero)
    let rect = pill.shapeRect(level: .expanded, contentSize: CGSize(width: 400, height: 200))
    #expect(rect.size == CGSize(width: 400, height: anchor.height + 200))
    expectCentredAndHanging(rect, from: anchor)
}

@Test(arguments: [notched, pill])
func panelContainsTheLargestShapeWithMargin(geometry: NotchGeometry) {
    let largest = geometry.shapeRect(level: .expanded, contentSize: NotchLimits.maxExpandedSize)
    let panel = geometry.panelFrame
    #expect(panel.contains(largest))
    #expect(panel.minX <= largest.minX - NotchGeometry.shadowMargin)
    #expect(panel.minY <= largest.minY - NotchGeometry.shadowMargin)
    #expect(panel.maxY <= screen.maxY)
}

@Test func notchPanelIsFlushWithTheScreenTop() {
    #expect(notched.panelFrame.maxY == screen.maxY)
    #expect(notched.localRect(notch).minY == 0)
}

@Test func localRectIsTopLeftOrigin() {
    let local = notched.localRect(notch)
    #expect(local.size == notch.size)
    #expect(local.midX == notched.panelFrame.width / 2)
}

@Test func hoverStaysInsideTheEntryRectWhileTheShapeShrinks() {
    var tracker = HoverTracker()
    let big = CGRect(x: 0, y: 0, width: 100, height: 100)
    let small = CGRect(x: 25, y: 50, width: 50, height: 50)
    let entered = tracker.update(pointer: CGPoint(x: 10, y: 10), shape: big)
    #expect(entered)
    #expect(tracker.isInside)
    // The shape shrank under the pointer; the entry rect keeps it inside.
    let changedOnShrink = tracker.update(pointer: CGPoint(x: 10, y: 10), shape: small)
    #expect(!changedOnShrink)
    #expect(tracker.isInside)
    let left = tracker.update(pointer: CGPoint(x: 200, y: 200), shape: small)
    #expect(left)
    #expect(!tracker.isInside)
}

@Test func aShownShapeIsOneRectFromTheTopEdgeAndAllOfItHits() {
    let shape = notched.shapeRect(level: .peek, contentSize: CGSize(width: 340, height: 36))
    // Wider than the notch, from the screen's top edge.
    #expect(shape.maxY == notch.maxY)
    #expect(shape.width == 340)
    // Level with the notch but beside it, over the menu bar: inside the shape.
    #expect(NotchGeometry.hits(shape, CGPoint(x: shape.minX + 5, y: notch.midY)))
    #expect(NotchGeometry.hits(shape, CGPoint(x: shape.maxX - 5, y: notch.midY)))
    #expect(!NotchGeometry.hits(shape, CGPoint(x: shape.minX - 5, y: notch.midY)))
}

@Test func wingShapeWidensTheNotchToItsLeadingSideOnly() {
    let rect = notched.wingShapeRect(wingWidth: 50)
    #expect(rect.maxX == notch.maxX)
    #expect(rect.minX == notch.minX - 50)
    #expect(rect.minY == notch.minY)
    #expect(rect.height == notch.height)
    // Clamped to the widest wing.
    #expect(notched.wingShapeRect(wingWidth: 900).width == notch.width + NotchLimits.maxWingWidth)
}

@Test func hoverStaysInsideWhenTheWingExpandsUnderThePointer() {
    var tracker = HoverTracker()
    let wingShape = CGRect(x: 50, y: 70, width: 150, height: 30)
    let expanded = CGRect(x: 0, y: 0, width: 300, height: 100)
    let inWing = CGPoint(x: 60, y: 85)
    let entered = tracker.update(pointer: inWing, shape: wingShape)
    #expect(entered)
    // Hover expanded the shape. The pointer has not moved and stays inside.
    let changed = tracker.update(pointer: inWing, shape: expanded)
    #expect(!changed)
    #expect(tracker.isInside)
}
