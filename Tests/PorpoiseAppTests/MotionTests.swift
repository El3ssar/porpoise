import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// One motion system: the shared interpolation, the frame clock under every animation, and the hover fade following
/// Reduce Motion like the rest. Each animation runs once for what it shows (W-196).
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
        let animator = Animator(name: "test")
        var steps: [Double] = []
        var second = false
        animator.run(duration: 0.05, step: { _ in }) {
            animator.run(duration: 0.05, step: { steps.append($0) }) { second = true }
        }
        await expectEventually { second }
        #expect(second && steps.last == 1)
    }

    /// A display that gives no frames (asleep) still lets animations end: the clock's timer ticks instead (W-139).
    /// Fixed frames, so a stalled machine still shows the steps between the first and the last.
    @Test func animationsEndWithoutDisplayFrames() async throws {
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        FrameClock.followsDisplay = false
        FrameClock.frameStep = 1.0 / 60
        defer { Animator.reducesMotion = reduces; FrameClock.followsDisplay = true; FrameClock.frameStep = nil }
        let animator = Animator(name: "test")
        var steps: [Double] = []
        var done = false
        animator.run(duration: 0.2, step: { steps.append($0) }) { done = true }
        await expectEventually { done }
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
        try #require(await poll { list.model.rows.count >= 3 })
        list.layoutSubtreeIfNeeded()
        let url = list.model.rows[0].item.url

        Animator.reducesMotion = { true }
        list.hoverIndex = 0
        #expect(list.hoverFade.alpha[url] == 1 && !list.hoverFade.isRunning)
        list.hoverIndex = nil
        #expect(list.hoverFade.alpha[url] == nil)

        Animator.reducesMotion = { false }
        list.hoverIndex = 0
        #expect((list.hoverFade.alpha[url] ?? 0) < 1)
        await expectEventually { list.hoverFade.alpha[url] == 1 }
        #expect(list.hoverFade.alpha[url] == 1)
        await expectEventually { !list.hoverFade.isRunning }
        #expect(!list.hoverFade.isRunning)
    }

    /// The Applications grid's hover highlight fades in like the file views' (the same `HoverFade`), and switches at
    /// once with Reduce Motion.
    @Test func theAppsGridHoverFadesLikeTheFileViews() async throws {
        let reduces = Animator.reducesMotion
        defer { Animator.reducesMotion = reduces }
        let scratch = try Scratch()
        for n in 1...3 { _ = try scratch.file("app \(n).txt") }
        let model = try await DirectoryModel.loaded(scratch.url)
        let grid = AppsGridView(model: model)
        grid.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        grid.updateLayout(width: 600)
        let url = model.rows[0].item.url

        Animator.reducesMotion = { true }
        grid.setHover(0)
        #expect(grid.hoverFade.alpha[url] == 1 && !grid.hoverFade.isRunning)
        grid.setHover(nil)
        #expect(grid.hoverFade.alpha[url] == nil)

        Animator.reducesMotion = { false }
        grid.setHover(0)
        #expect((grid.hoverFade.alpha[url] ?? 0) < 1)
        await expectEventually { grid.hoverFade.alpha[url] == 1 }
        #expect(grid.hoverFade.alpha[url] == 1)
        grid.setHover(nil)
        await expectEventually { grid.hoverFade.alpha[url] == nil }
        #expect(grid.hoverFade.alpha[url] == nil && !grid.hoverFade.isRunning)
    }

    private func browser(_ s: Scratch, files: Int) async throws -> MainWindowController {
        for n in 1...files { _ = try s.file("file \(n).txt") }
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppDelegate.shared.newWindow(at: s.url)
        let wc = try #require(AppDelegate.shared.windows.last)
        wc.window?.setFrame(CGRect(x: 0, y: 0, width: 1000, height: 600), display: true)
        wc.window?.orderFront(nil)
        wc.view.setMode(.icons)
        try #require(await poll { wc.view.model.rows.count >= files })
        return wc
    }

    /// Information sliding in and out: the files glide to their new places once over each slide, and end laid out at
    /// their real width, instead of a glide starting over at every column the narrowing width passed.
    @Test func aPanelSlideGlidesTheFilesOnce() async throws {
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        defer {
            Animator.reducesMotion = reduces
            MotionLog.isRecording = false
            MotionLog.runs = []
        }
        let scratch = try Scratch()
        let wc = try await browser(scratch, files: 40)
        defer { wc.window?.close() }
        wc.showInformation = false
        wc.rebuildPanels()
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let info = NSMenuItem()
        info.tag = 1
        for opening in [true, false] {
            MotionLog.runs = []
            MotionLog.isRecording = true
            wc.togglePanel(info)
            await expectEventually { !wc.panelAnimator.isRunning && !wc.view.list.transitionAnimator.isRunning }
            MotionLog.isRecording = false
            let glides = MotionLog.runs.filter { $0.name == "list.glide" }
            #expect(glides.count == 1 && glides.allSatisfy { $0.end == .finished }, "opening \(opening): \(glides.map(\.end))")
            #expect(wc.showInformation == opening && wc.view.list.layoutWidthOverride == nil)
        }
    }

    /// Going to another folder clears the filter without animating it first (that glide stopped at once, its pictures
    /// taken for nothing), and a filter that didn't change animates nothing.
    @Test func navigatingAndUnchangedFiltersStartNoGlide() async throws {
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        defer { Animator.reducesMotion = reduces }
        let scratch = try Scratch()
        let other = try scratch.file("other/inside.txt").deletingLastPathComponent()
        let wc = try await browser(scratch, files: 5)
        defer { wc.window?.close() }
        let view = wc.view
        let started = view.list.transitions.log.count
        view.filterBar(view.filterBar, changed: NameFilter())
        view.setURL(other)
        try #require(await poll { view.model.rows.count == 1 })
        #expect(view.list.transitions.log.count == started, "\(view.list.transitions.log)")
    }
}
