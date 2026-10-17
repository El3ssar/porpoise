import AppKit

/// How things move in the app, in one place: how long each kind of motion takes, and the interpolation every
/// animation shares. The clock is `FrameClock` (and `Animator` on it); Reduce Motion is `Animator.reducesMotion`.
enum Motion {
    /// Items gliding to their new places: a filter, a search, a remote change, a reflow.
    static let glide: TimeInterval = 0.3
    /// The split view: copies flying between the panes as it opens, the pane sliding open and closed (its flights back
    /// take as long), the handle going back to the middle.
    static let flight: TimeInterval = 0.42
    static let splitOpen: TimeInterval = 0.28
    static let splitClose: TimeInterval = 0.24
    static let splitReset: TimeInterval = 0.2
    /// A control fading in or out.
    static let fade: TimeInterval = 0.18
    /// The hover highlight (Breeze animates hover): quick in, a little slower out.
    static let hoverIn: TimeInterval = 0.085
    static let hoverOut: TimeInterval = 0.14

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ p: CGFloat) -> CGPoint { CGPoint(x: lerp(a.x, b.x, p), y: lerp(a.y, b.y, p)) }
    /// Position and size both on their way from `a` to `b`.
    static func lerp(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
        CGRect(origin: lerp(a.origin, b.origin, p), size: CGSize(width: lerp(a.width, b.width, p), height: lerp(a.height, b.height, p)))
    }

    /// 0 until `p` reaches `a`, 1 from `b`, easing in and out between: one look handing over to another.
    static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat {
        let x = min(1, max(0, (p - a) / (b - a)))
        return x * x * (3 - 2 * x)
    }

    /// An item coming in (Icons): it grows from 82 % while it fades in (`a`: how far it has come).
    static func appearScale(_ a: CGFloat) -> CGFloat { 0.82 + 0.18 * a }
    /// An item going away: it fades out quickly, shrinking a little (in Icons) while it does.
    static func leave(_ p: CGFloat) -> (alpha: CGFloat, scale: CGFloat) { (max(0, 1 - p * 1.6), 1 - 0.18 * p) }
}

/// Calls `tick` once per frame the display shows (in the common run loop modes, so it keeps going during live resize
/// and other event tracking), with the frame's time, until `tick` returns false or `stop` is called.
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var tick: ((CFTimeInterval) -> Bool)?

    /// False when there is no screen to follow (nothing runs then).
    @discardableResult func run(_ tick: @escaping (CFTimeInterval) -> Bool) -> Bool {
        stop()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        self.tick = tick
        let l = screen.displayLink(target: self, selector: #selector(frame(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        return true
    }

    @objc private func frame(_ l: CADisplayLink) {
        guard l === link, let tick else { return l.invalidate() }
        // `tick` may have started the clock again (an animation's completion starting the next): only this run ends.
        if !tick(l.timestamp), l === link { stop() }
    }

    var isRunning: Bool { link != nil }

    func stop() {
        link?.invalidate()
        link = nil
        tick = nil
    }
}
