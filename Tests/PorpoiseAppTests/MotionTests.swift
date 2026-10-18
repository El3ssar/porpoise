import AppKit
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// One motion system: the shared interpolation, the frame clock under every animation, and the hover fade following
/// Reduce Motion like the rest.
@Suite(.serialized, .isolatedSettings) @MainActor struct MotionTests {
    @Test func interpolationIsSharedAndExact() {
        let a = CGRect(x: 0, y: 10, width: 100, height: 40), b = CGRect(x: 50, y: 30, width: 50, height: 80)
        #expect(Motion.lerp(a, b, 0) == a && Motion.lerp(a, b, 1) == b)
        #expect(Motion.lerp(a, b, 0.5) == CGRect(x: 25, y: 20, width: 75, height: 60))
        #expect(Motion.smoothstep(0.2, 0.6, 0.1) == 0 && Motion.smoothstep(0.2, 0.6, 0.7) == 1)
        #expect(abs(Motion.smoothstep(0.2, 0.6, 0.4) - 0.5) < 1e-9)
        #expect(Motion.appearScale(0) == 0.82 && Motion.appearScale(1) == 1)
        #expect(Motion.leave(0) == (1, 1) && Motion.leave(1).alpha == 0 && abs(Motion.leave(1).scale - 0.82) < 1e-9)
    }

    /// An animation whose completion starts the next one on the same animator keeps running (the frame that ended the
    /// first must not stop the second).
    @Test func aCompletionCanStartTheNextAnimation() async throws {
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        defer { Animator.reducesMotion = reduces }
        let animator = Animator()
        var steps: [Double] = []
        var second = false
        animator.run(duration: 0.05, step: { _ in }) {
            animator.run(duration: 0.05, step: { steps.append($0) }) { second = true }
        }
        _ = await poll(timeout: 5) { second }
        #expect(second && steps.last == 1)
    }

    /// A display that gives no frames (asleep) still lets animations end: the clock's timer ticks instead (W-139).
    @Test func animationsEndWithoutDisplayFrames() async throws {
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        FrameClock.followsDisplay = false
        defer { Animator.reducesMotion = reduces; FrameClock.followsDisplay = true }
        let animator = Animator()
        var steps: [Double] = []
        var done = false
        animator.run(duration: 0.2, step: { steps.append($0) }) { done = true }
        _ = await poll(timeout: 5) { done }
        #expect(done && steps.last == 1 && steps.count >= 3)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// The hover highlight fades in over a few frames; with Reduce Motion it is there at once. With no display frames
    /// it fades in all the same.
    @Test(arguments: [true, false]) func hoverFadesUnlessMotionIsReduced(followsDisplay: Bool) async throws {
        FrameClock.followsDisplay = followsDisplay
        defer { FrameClock.followsDisplay = true }
        let reduces = Animator.reducesMotion
        defer { Animator.reducesMotion = reduces }
        let scratch = try Scratch(), folder = scratch.url
        for n in 1...3 { try Data("\(n)".utf8).write(to: folder.appendingPathComponent("file \(n).txt")) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = PorpoiseTab(url: folder)
        window.contentView = tab
        let list = tab.primary.list
        _ = await poll(timeout: 6) { list.model.rows.count >= 3 }
        list.layoutSubtreeIfNeeded()
        let url = list.model.rows[0].item.url

        Animator.reducesMotion = { true }
        list.hoverIndex = 0
        #expect(list.hoverAlpha[url] == 1 && !list.hoverClock.isRunning)
        list.hoverIndex = nil
        #expect(list.hoverAlpha[url] == nil)

        Animator.reducesMotion = { false }
        list.hoverIndex = 0
        #expect((list.hoverAlpha[url] ?? 0) < 1)
        _ = await poll(timeout: 5) { list.hoverAlpha[url] == 1 }
        #expect(list.hoverAlpha[url] == 1)
        _ = await poll(timeout: 5) { !list.hoverClock.isRunning }
        #expect(!list.hoverClock.isRunning)
    }
}
