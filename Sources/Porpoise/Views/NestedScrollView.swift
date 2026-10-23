import AppKit

/// A scroll view that can sit in another one, as a column sits in Column view's strip: it scrolls its own content
/// up and down, and hands a sideways scroll it has no room for (a trackpad swipe, a mouse wheel's tilt, ⇧ and the
/// wheel) to the scroll view around it, which AppKit's own doesn't do.
final class NestedScrollView: NSScrollView {
    /// Whether the scroll going on is sideways: decided as a gesture starts and kept to the end of its momentum (the
    /// columns moving under the pointer may hand its next events to another column's view).
    private static var sideways = false

    override func scrollWheel(with event: NSEvent) {
        if Self.isSideways(event), let outer = enclosingScrollView, !scrollsSideways {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// Whether `event` belongs to a sideways scroll: a wheel's own, or the trackpad gesture that started so (fingers
    /// resting before it starts aren't one yet).
    static func isSideways(_ event: NSEvent) -> Bool {
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        return sideways && event.phase != .mayBegin
    }

    /// Its content is wider than it shows.
    private var scrollsSideways: Bool { (documentView?.frame.width ?? 0) > contentView.bounds.width + 0.5 }
}
