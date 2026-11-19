import CoreGraphics

/// Decides whether the pointer is inside the notch shape, with hysteresis.
///
/// Hovering changes the level, which changes the shape. Without hysteresis a
/// pointer at the edge could leave the new shape and flicker. While inside, the
/// pointer stays inside as long as it is in the current shape or in the shape it
/// had on entry.
struct HoverTracker {
    private(set) var isInside = false
    private var entryRect = CGRect.null
    /// The neck that went with `entryRect`. A wing shape has none, and the
    /// expanded shape that replaces it does; each is tested with its own.
    private var entryNeck: CGRect?

    /// Returns true when `isInside` changed.
    mutating func update(pointer: CGPoint, shape: CGRect, neck: CGRect? = nil) -> Bool {
        let inside = NotchGeometry.hits(shape, pointer, neck: neck)
            || (isInside && NotchGeometry.hits(entryRect, pointer, neck: entryNeck))
        guard inside != isInside else { return false }
        isInside = inside
        entryRect = inside ? shape : .null
        entryNeck = inside ? neck : nil
        return true
    }
}
