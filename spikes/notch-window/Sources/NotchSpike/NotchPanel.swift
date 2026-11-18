import AppKit

/// Borderless, non-activating panel that can never become key or main.
///
/// DESIGN CHOICE (resize vs large panel): the panel is created once at the size of
/// the expanded state (+ shadow margin) and never resized. Only the SwiftUI shape
/// inside animates. Reason: animating NSWindow frames and SwiftUI layout together
/// tends to stutter / desync; a fixed panel lets SwiftUI own the whole animation.
///
/// HIT TESTING: the transparent part of the panel must not swallow clicks meant for
/// the menu bar or the app below. The panel starts with ignoresMouseEvents = true.
/// The controller polls NSEvent.mouseLocation (60 Hz) and sets
/// ignoresMouseEvents = false only while the cursor is inside the current shape rect.
/// So outside the black shape every click falls through to whatever is below.
/// Polling also means hover detection does not depend on the window receiving
/// mouse-moved events at all (which it cannot while ignoring mouse events).
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit may push windows out of the menu bar area. Keep the frame we asked for.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(frame: CGRect, level: NSWindow.Level) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false            // shadow is drawn by SwiftUI on the shape only
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false    // NSPanel default is true; we are never "active" anyway
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }
}
