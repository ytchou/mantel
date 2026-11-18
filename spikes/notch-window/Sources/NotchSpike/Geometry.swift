import AppKit

enum NotchState: String {
    case idle, peek, expanded
}

/// All rects are in global AppKit screen coordinates (origin bottom-left of the
/// primary display, y up).
struct NotchGeometry {
    /// true when the screen reports a notch and --force-pill was not passed.
    let isNotchMode: Bool
    let screenHasNotch: Bool
    let screenFrame: CGRect
    /// The real notch rect (notch mode) or the idle pill rect (pill mode).
    let anchorRect: CGRect
    /// Margin around the expanded shape inside the panel, room for the shadow.
    static let shadowMargin: CGFloat = 30

    /// Notch rect from NSScreen, not hard-coded:
    /// x from auxiliaryTopLeftArea.maxX to auxiliaryTopRightArea.minX,
    /// height from safeAreaInsets.top, top flush with the screen top.
    /// Assumption: the auxiliary areas are in the screen's own coordinate space, so we
    /// add screen.frame.minX. For the built-in (primary) display origin is 0, so this
    /// is the same either way.
    static func notchRect(of screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              screen.safeAreaInsets.top > 0 else { return nil }
        let height = screen.safeAreaInsets.top
        let minX = screen.frame.minX + left.maxX
        let maxX = screen.frame.minX + right.minX
        guard maxX > minX else { return nil }
        return CGRect(x: minX, y: screen.frame.maxY - height, width: maxX - minX, height: height)
    }

    static func compute(screen: NSScreen, forcePill: Bool) -> NotchGeometry {
        let notch = notchRect(of: screen)
        if let notch, !forcePill {
            return NotchGeometry(isNotchMode: true, screenHasNotch: true,
                                 screenFrame: screen.frame, anchorRect: notch)
        }
        // Pill: centred, just under the menu bar.
        var menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBar <= 0 { menuBar = 24 } // menu bar auto-hidden; arbitrary fallback
        let size = CGSize(width: 200, height: 32)
        let top = screen.frame.maxY - menuBar - 6
        let pill = CGRect(x: screen.frame.midX - size.width / 2, y: top - size.height,
                          width: size.width, height: size.height)
        return NotchGeometry(isNotchMode: false, screenHasNotch: notch != nil,
                             screenFrame: screen.frame, anchorRect: pill)
    }

    var anchorTop: CGFloat { anchorRect.maxY }

    func size(for state: NotchState) -> CGSize {
        let w = anchorRect.width, h = anchorRect.height
        switch state {
        case .idle: return CGSize(width: w, height: h)
        case .peek: return CGSize(width: w + 36, height: h + 6)
        case .expanded: return CGSize(width: max(420, w + 40), height: max(160, h + 40))
        }
    }

    /// (top, bottom) corner radii. Notch mode keeps the top square so the shape is
    /// flush with the screen edge; pill mode rounds all four.
    func radii(for state: NotchState) -> (top: CGFloat, bottom: CGFloat) {
        if isNotchMode {
            switch state {
            case .idle: return (0, 8)
            case .peek: return (0, 12)
            case .expanded: return (0, 24)
            }
        }
        switch state {
        case .idle: return (16, 16)
        case .peek: return (19, 19)
        case .expanded: return (24, 24)
        }
    }

    /// Where the black shape sits on screen for a state: hangs down from anchorTop,
    /// centred on the notch.
    func shapeRect(for state: NotchState) -> CGRect {
        let s = size(for: state)
        return CGRect(x: anchorRect.midX - s.width / 2, y: anchorTop - s.height,
                      width: s.width, height: s.height)
    }

    /// Large, fixed, transparent panel big enough for the expanded state + shadow.
    /// Top edge = anchorTop (screen top in notch mode).
    var panelFrame: CGRect {
        let e = size(for: .expanded)
        let w = e.width + 2 * Self.shadowMargin
        let h = e.height + Self.shadowMargin
        return CGRect(x: anchorRect.midX - w / 2, y: anchorTop - h, width: w, height: h)
    }
}
