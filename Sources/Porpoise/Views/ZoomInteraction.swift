import AppKit
import PorpoiseCore

/// A view that zooms like the Icons view: a size shown live, then saved.
protocol ZoomableView: AnyObject {
    var iconSize: CGFloat { get }
    func previewZoom(_ size: CGFloat, anchor: CGPoint?, commitAfter delay: TimeInterval?)
    func animateZoom(to size: CGFloat)
    func commitZoom()
    /// How far a reflow glide has come, while one runs (for the debug bridge).
    var glideProgress: CGFloat? { get }
}

/// The zoom gestures, the same in the folder view and the Applications grid.
extension ZoomableView where Self: NSView {
    /// Cmd+wheel or Cmd+two-finger scroll zooms around the pointer, smoothly (trackpads) or by Dolphin's steps (mouse
    /// wheels). False without Cmd: the view scrolls.
    func zoomWithWheel(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        let p = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas {
            let level = ZoomLevels.continuousLevel(for: iconSize) + Double(event.scrollingDeltaY) * 0.02
            previewZoom(ZoomLevels.size(forContinuousLevel: level), anchor: p, commitAfter: 0.35)
        } else if event.scrollingDeltaY != 0 {
            previewZoom(ZoomLevels.step(from: iconSize, by: event.scrollingDeltaY > 0 ? 1 : -1), anchor: p, commitAfter: 0.35)
        }
        return true
    }

    /// Pinch: continuous zoom around the fingers, saved when the gesture ends.
    func zoomWithPinch(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        previewZoom(iconSize * (1 + event.magnification), anchor: p, commitAfter: event.phase == .ended || event.phase == .cancelled ? 0 : 0.5)
    }
}
