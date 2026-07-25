import Foundation

/// Pure drag-threshold decision shared by the AppKit bridge and regression tests.
public enum DragGesturePolicy {
    public static let defaultThreshold: CGFloat = 4

    public static func shouldBeginDrag(
        mouseDown: CGPoint,
        current: CGPoint,
        threshold: CGFloat = defaultThreshold
    ) -> Bool {
        guard threshold >= 0 else { return false }
        let dx = current.x - mouseDown.x
        let dy = current.y - mouseDown.y
        return (dx * dx) + (dy * dy) > threshold * threshold
    }
}
