import AppKit

/// How things move in the app, in one place: how long each kind of motion takes, and the interpolation every
/// animation shares. The clock is `FrameClock` (and `Animator` on it); Reduce Motion is `Animator.reducesMotion`.
enum Motion {
    /// Items gliding to their new places: a filter, a search, a remote change, a reflow.
    static let glide: TimeInterval = 0.3
    /// Search results coming in one after another; a listing changed elsewhere settling in.
    static let searchResults: TimeInterval = 0.45
    static let remote: TimeInterval = 0.35
    /// The split view: copies flying between the panes as it opens, the pane sliding open and closed (its flights back
    /// take as long), the handle going back to the middle.
    static let flight: TimeInterval = 0.42
    static let splitOpen: TimeInterval = 0.28
    static let splitClose: TimeInterval = 0.24
    static let splitReset: TimeInterval = 0.2
    /// A panel (Places, Information) sliding in and out; Places sections folding.
    static let panelOpen: TimeInterval = 0.22
    static let panelClose: TimeInterval = 0.18
    static let fold: TimeInterval = 0.24
    /// The Column view scrolling to a new column; the zoom steps (Cmd+= and Cmd+-).
    static let scroll: TimeInterval = 0.22
    static let zoomStep: TimeInterval = 0.16
    /// The Applications grid's items gliding to new places.
    static let appsGlide: TimeInterval = 0.34
    /// A control fading in or out.
    static let fade: TimeInterval = 0.18
    /// The Space preview window zooming out of its item and back.
    static let previewZoom: TimeInterval = 0.16
    /// A progress bar's fill moving to its new fraction.
    static let progress: TimeInterval = 0.16
    /// One sweep of an indeterminate progress bar's band (it repeats; Reduce Motion stops it).
    static let indeterminate: TimeInterval = 1.2
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

    /// What runs on it, for `MotionLog` ("places.fold", "hover"…).
    let name: String
    private var link: CADisplayLink?
    private var timer: Timer?
    private var tick: ((CFTimeInterval) -> Bool)?
    private var lastFrame: CFTimeInterval = 0, lastTime: CFTimeInterval = 0
    private var logged: Int?

    init(name: String) {
        self.name = name
    }

    /// False when there is no screen to follow (nothing runs then).
    @discardableResult func run(_ tick: @escaping (CFTimeInterval) -> Bool) -> Bool {
        stop()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        self.tick = tick
        lastFrame = CACurrentMediaTime()
        lastTime = 0
        logged = MotionLog.begin(name)
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
        let run = logged, started = CACurrentMediaTime()
        let more = tick(lastTime)
        MotionLog.frame(run, at: now, work: CACurrentMediaTime() - started, last: !more)
        // `tick` may have started the clock again (an animation's completion starting the next): only this run ends.
        if !more, running === timer { stop() }
    }

    var isRunning: Bool { timer != nil }

    func stop() {
        MotionLog.stop(logged)
        logged = nil
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        tick = nil
    }
}

/// Hover highlights fading in and out (`Motion.hoverIn`, `.hoverOut`), each item's from where it is, so moving across
/// items hands the highlight over smoothly; with Reduce Motion they just switch. The file views and the Applications
/// grid share it, so hover looks the same in both.
final class HoverFade {
    /// Each highlight's opacity while it shows or fades (none: no highlight).
    private(set) var alpha: [URL: CGFloat] = [:]
    /// The item under the pointer, asked at every step (the items may change under a still pointer).
    var target: () -> URL? = { nil }
    /// Draws an item again: its highlight changed.
    var redraw: (URL) -> Void = { _ in }
    private let clock: FrameClock

    init(name: String) {
        clock = FrameClock(name: name)
    }

    var isRunning: Bool { clock.isRunning }

    /// The pointer moved to another item (or off them): highlights head for their new opacity.
    func update() {
        if let t = target(), alpha[t] == nil { alpha[t] = 0.01 }
        if Animator.reducesMotion() {
            clock.stop()
            step(by: 1)
            return
        }
        guard !clock.isRunning else { return }
        var last = CACurrentMediaTime()
        clock.run { [weak self] now in
            defer { last = now }
            return self?.step(by: CGFloat(max(0, now - last))) ?? false
        }
    }

    func stop() { clock.stop() }

    /// Moves each highlight `seconds` further toward its goal (a whole fade: 1 with Reduce Motion); true while some are
    /// still on their way.
    @discardableResult private func step(by seconds: CGFloat) -> Bool {
        let target = target()
        var moving = false
        for (u, a) in alpha {
            let goal: CGFloat = u == target ? 1 : 0
            let next = goal > a ? min(1, a + seconds / Motion.hoverIn) : max(0, a - seconds / Motion.hoverOut)
            if next == 0 && goal == 0 { alpha.removeValue(forKey: u) } else { alpha[u] = next }
            if next != goal { moving = true }
            redraw(u)
        }
        return moving
    }
}

/// What the animations did while a probe records (the debug bridge's `motionlog`): each run of each clock, the times
/// of the frames it drew, how long each step took and how it ended. Not recording, it costs one check per frame.
enum MotionLog {
    enum End: String { case running, finished, stopped, jumped }
    struct Run {
        let name: String
        let start: CFTimeInterval
        var frames: [CFTimeInterval] = []
        var work: [CFTimeInterval] = []
        var end = End.running
    }

    nonisolated(unsafe) static var isRecording = false
    nonisolated(unsafe) static var runs: [Run] = []

    /// A run starting: its index, or nil when not recording.
    static func begin(_ name: String) -> Int? {
        guard isRecording else { return nil }
        runs.append(Run(name: name, start: CACurrentMediaTime()))
        return runs.count - 1
    }

    static func frame(_ i: Int?, at time: CFTimeInterval, work: CFTimeInterval, last: Bool) {
        guard let i, runs.indices.contains(i) else { return }
        runs[i].frames.append(time)
        runs[i].work.append(work)
        if last { runs[i].end = .finished }
    }

    /// Stopped before its last frame (replaced or cancelled), unless it had finished.
    static func stop(_ i: Int?) {
        guard let i, runs.indices.contains(i), runs[i].end == .running else { return }
        runs[i].end = .stopped
    }

    /// Reduce Motion or no screen: the animation went straight to its end, with no frames.
    static func jump(_ name: String) {
        guard isRecording else { return }
        runs.append(Run(name: name, start: CACurrentMediaTime(), end: .jumped))
    }
}
