import AppKit

/// Borderless, non-activating panel that can never become key or main.
///
/// Created once at the size of the largest shape plus a shadow margin and never
/// resized; only the SwiftUI shape inside animates. `ignoresMouseEvents` starts
/// true; the controller turns it off only while the pointer is over the shape,
/// so the transparent part never takes clicks.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit may push windows out of the menu bar area. Keep the frame asked for.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(frame: CGRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the shape draws its own shadow
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }
}
