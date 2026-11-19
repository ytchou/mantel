import AppKit
import NotchCore

/// Where the notch shape sits on one screen. Pure arithmetic; reading `NSScreen`
/// is kept in `current()` so the rest can be tested with made-up rects.
///
/// All rects are in global AppKit screen coordinates (origin at the bottom-left
/// of the primary display, y up).
struct NotchGeometry: Equatable {
    /// True when the screen has a hardware notch. False means a floating pill.
    let isNotch: Bool
    /// The hardware notch rect, or the idle pill rect.
    let anchorRect: CGRect
    /// Top of the screen the anchor is on.
    let screenTop: CGFloat

    /// Room around the largest shape inside the panel, for the shadow.
    static let shadowMargin: CGFloat = 30
    static let pillSize = CGSize(width: 200, height: 32)
    /// Gap between the menu bar and the pill.
    static let pillGap: CGFloat = 6
    /// Used when the menu bar is hidden and the screen reports no height for it.
    static let fallbackMenuBarHeight: CGFloat = 24

    init(isNotch: Bool, anchorRect: CGRect, screenTop: CGFloat) {
        self.isNotch = isNotch
        self.anchorRect = anchorRect
        self.screenTop = screenTop
    }

    /// Notch mode when `notch` is set, else a pill centred under the menu bar.
    init(screenFrame: CGRect, visibleFrame: CGRect, notch: CGRect?) {
        if let notch {
            self.init(isNotch: true, anchorRect: notch, screenTop: screenFrame.maxY)
            return
        }
        var menuBar = screenFrame.maxY - visibleFrame.maxY
        if menuBar <= 0 { menuBar = Self.fallbackMenuBarHeight }
        let size = Self.pillSize
        let top = screenFrame.maxY - menuBar - Self.pillGap
        let pill = CGRect(x: screenFrame.midX - size.width / 2, y: top - size.height,
                          width: size.width, height: size.height)
        self.init(isNotch: false, anchorRect: pill, screenTop: screenFrame.maxY)
    }

    /// The notch rect from the screen's auxiliary areas and top safe-area inset:
    /// x from the left area's maxX to the right area's minX, top flush with the
    /// screen. The auxiliary areas are in the screen's own coordinates.
    static func notchRect(screenFrame: CGRect, topLeft: CGRect?, topRight: CGRect?, safeTop: CGFloat) -> CGRect? {
        guard let topLeft, let topRight, safeTop > 0 else { return nil }
        let minX = screenFrame.minX + topLeft.maxX
        let maxX = screenFrame.minX + topRight.minX
        guard maxX > minX else { return nil }
        return CGRect(x: minX, y: screenFrame.maxY - safeTop, width: maxX - minX, height: safeTop)
    }

    // MARK: Shape

    /// Height of the strip at the top of the shape that holds no content: the
    /// hardware notch (or the idle pill).
    var headerHeight: CGFloat { anchorRect.height }

    /// The shape for a level and wanted content size. `nil` level is idle.
    /// The shape starts at the anchor's top (the screen edge on a notched
    /// screen), centred on it, at least as wide as it, and grows downward by
    /// the clamped content height. It is one rounded rectangle: the whole
    /// notch grows, covering the menu bar beside it while it is shown.
    func shapeRect(level: NotchLevel?, contentSize: CGSize) -> CGRect {
        guard let level else { return anchorRect }
        let content = NotchLimits.clamp(contentSize, for: level)
        let width = max(anchorRect.width, content.width)
        let height = anchorRect.height + content.height
        return CGRect(x: anchorRect.midX - width / 2, y: anchorRect.maxY - height,
                      width: width, height: height)
    }

    /// The shape with a wing: the anchor, widened to its leading side by the
    /// wing's width and no taller. The wing sits inside the menu bar, on the
    /// side of the app menus; the other side holds the status items, which
    /// start right at the notch. A pill is wide enough already and keeps its rect.
    func wingShapeRect(wingWidth: CGFloat) -> CGRect {
        guard isNotch else { return anchorRect }
        let width = min(max(wingWidth, 0), NotchLimits.maxWingWidth)
        return CGRect(x: anchorRect.minX - width, y: anchorRect.minY,
                      width: anchorRect.width + width, height: anchorRect.height)
    }

    /// (top, bottom) corner radii. Notch mode keeps the top square so the shape is
    /// flush with the screen edge; pill mode rounds all four corners.
    func radii(level: NotchLevel?) -> (top: CGFloat, bottom: CGFloat) {
        let bottom: CGFloat = switch level {
        case nil: isNotch ? 8 : 16
        case .peek: 14
        case .expanded: 24
        }
        return (isNotch ? 0 : bottom, bottom)
    }

    // MARK: Panel

    /// Fixed panel frame, big enough for the largest shape plus the shadow margin.
    var panelFrame: CGRect {
        let largest = shapeRect(level: .expanded, contentSize: NotchLimits.maxExpandedSize)
        let width = largest.width + 2 * Self.shadowMargin
        let top = min(screenTop, anchorRect.maxY + Self.shadowMargin)
        let bottom = largest.minY - Self.shadowMargin
        return CGRect(x: anchorRect.midX - width / 2, y: bottom, width: width, height: top - bottom)
    }

    /// A screen rect in the panel's SwiftUI coordinates (origin top-left, y down).
    func localRect(_ rect: CGRect) -> CGRect {
        let panel = panelFrame
        return CGRect(x: rect.minX - panel.minX, y: panel.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// Inclusive containment. The top edge gets one extra point so a pointer
    /// pinned at the very top of the screen still hits the notch.
    static func hits(_ rect: CGRect, _ point: CGPoint) -> Bool {
        !rect.isNull
            && point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY + 1
    }
}

// MARK: - Runtime state and screens

@MainActor
extension NotchGeometry {
    /// Content shown for a state, if any.
    static func content(for state: NotchState) -> NotchContent? {
        guard case let .showing(_, level, presentation) = state else { return nil }
        if level == .peek { return presentation.wing == nil ? presentation.peek : nil }
        return presentation.expanded
    }

    /// The wing shown for a state, if any: at the peek level, a wing wins over the peek strip.
    static func wing(for state: NotchState) -> NotchContent? {
        guard case let .showing(_, .peek, presentation) = state else { return nil }
        return presentation.wing
    }

    func shapeRect(for state: NotchState) -> CGRect {
        if let wing = Self.wing(for: state) { return wingShapeRect(wingWidth: wing.size.width) }
        return shapeRect(level: state.level, contentSize: Self.content(for: state)?.size ?? .zero)
    }

    /// Geometry for the screens connected now. See `choose`.
    static func current(forcePill: Bool = false) -> NotchGeometry? {
        choose(screens: NSScreen.screens.map(ScreenInfo.init), main: NSScreen.main.map(ScreenInfo.init), forcePill: forcePill)
    }
}

/// What the geometry needs to know about one screen. Screen selection takes
/// these instead of `NSScreen`, so it can be tested with made-up screens.
struct ScreenInfo: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    /// The areas beside a hardware notch, in the screen's own coordinates. Nil without a notch.
    var topLeft: CGRect?
    var topRight: CGRect?
    var safeTop: CGFloat = 0
}

extension ScreenInfo {
    @MainActor
    init(_ screen: NSScreen) {
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame,
                  topLeft: screen.auxiliaryTopLeftArea, topRight: screen.auxiliaryTopRightArea,
                  safeTop: screen.safeAreaInsets.top)
    }
}

extension NotchGeometry {
    /// The first screen with a notch, else `main` (or the first screen) as a
    /// pill. `nil` when there is no screen at all, as with the lid closed and
    /// no display connected. `forcePill` ignores the notch, to try the pill on
    /// a notched Mac.
    static func choose(screens: [ScreenInfo], main: ScreenInfo?, forcePill: Bool = false) -> NotchGeometry? {
        for screen in screens where !forcePill {
            if let notch = notchRect(screenFrame: screen.frame, topLeft: screen.topLeft,
                                     topRight: screen.topRight, safeTop: screen.safeTop) {
                return NotchGeometry(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, notch: notch)
            }
        }
        guard let screen = main ?? screens.first else { return nil }
        return NotchGeometry(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, notch: nil)
    }
}
