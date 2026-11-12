import Foundation

/// Decides when the toolbar hides while typing and when it comes back.
///
/// Hiding happens on a keystroke. Showing again needs a real pointer movement:
/// a position in screen coordinates that moves at least `movementThreshold`
/// from the last real position. Hover callbacks, content shifting under a still
/// pointer, and scrolling all report the same position, so they never re-show
/// the chrome. Events within `graceInterval` of a hide are ignored, so the hide
/// animation can't bounce the chrome back.
struct ChromeVisibility {
    static let movementThreshold: CGFloat = 6
    static let graceInterval: TimeInterval = 0.4

    private(set) var isVisible = true
    /// The last pointer position (screen coordinates) that counted as movement.
    private var lastPointer: CGPoint?
    private var hiddenAt: TimeInterval = -.infinity

    /// Hides the chrome for a keystroke. Returns true only when this changed it.
    @discardableResult
    mutating func hide(at time: TimeInterval) -> Bool {
        guard isVisible else { return false }
        isVisible = false
        hiddenAt = time
        return true
    }

    /// Reports the pointer's screen position. Returns true when the chrome should show.
    @discardableResult
    mutating func pointerMoved(to point: CGPoint, at time: TimeInterval) -> Bool {
        guard let last = lastPointer else {
            lastPointer = point
            return false
        }
        guard hypot(point.x - last.x, point.y - last.y) >= Self.movementThreshold else { return false }
        lastPointer = point
        guard !isVisible, time - hiddenAt >= Self.graceInterval else { return false }
        isVisible = true
        return true
    }

    /// Forces the chrome visible (for example when auto-hide is switched off).
    mutating func reset() {
        isVisible = true
    }
}
