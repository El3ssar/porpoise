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
/// and other event tracking), with the frame's time, until `tick` returns false or `stop` is called. A display that
/// sleeps (or a window on one that shows nothing) gives no frames: a timer then ticks instead, so animations still
/// end and their completions still run.
final class FrameClock: NSObject {
    /// Tests: false leaves only the timer, as with a sleeping display.
    nonisolated(unsafe) static var followsDisplay = true
    /// Tests: each tick after a run's first moves its time on by exactly this much, whatever the clock says, so an
    /// animation goes through the same frames however slow the machine is (nil, the default: real time).
    nonisolated(unsafe) static var frameStep: CFTimeInterval?
    /// How long the display may go without a frame before the timer stands in, and how often it then ticks.
    static let quiet: CFTimeInterval = 0.1
    static let fallbackInterval: TimeInterval = 1.0 / 30

    private var link: CADisplayLink?
    private var timer: Timer?
    private var tick: ((CFTimeInterval) -> Bool)?
    private var lastFrame: CFTimeInterval = 0, lastTime: CFTimeInterval = 0

    /// False when there is no screen to follow (nothing runs then).
    @discardableResult func run(_ tick: @escaping (CFTimeInterval) -> Bool) -> Bool {
        stop()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        self.tick = tick
        lastFrame = CACurrentMediaTime()
        lastTime = 0
        if Self.followsDisplay {
            let l = screen.displayLink(target: self, selector: #selector(frame(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        // Display link timestamps and CACurrentMediaTime share one clock, so `tick` sees one timeline either way.
        let t = Timer(timeInterval: Self.fallbackInterval, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, t === self.timer else { return t.invalidate() }
                let now = CACurrentMediaTime()
                if now - self.lastFrame >= Self.quiet { self.deliver(now) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        return true
    }

    @objc private func frame(_ l: CADisplayLink) {
        guard l === link else { return l.invalidate() }
        lastFrame = CACurrentMediaTime()
        deliver(l.timestamp)
    }

    private func deliver(_ now: CFTimeInterval) {
        guard let tick, let running = timer else { return stop() }
        if let step = Self.frameStep {
            lastTime = lastTime == 0 ? now : lastTime + step
        } else {
            // A frame's time may trail the timer's last tick as the display wakes: time never runs back.
            lastTime = max(lastTime, now)
        }
        // `tick` may have started the clock again (an animation's completion starting the next): only this run ends.
        if !tick(lastTime), running === timer { stop() }
    }

    var isRunning: Bool { timer != nil }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        tick = nil
    }
}
