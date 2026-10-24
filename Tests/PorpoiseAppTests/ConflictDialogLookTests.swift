import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// The name-clash sheet is built from AppKit's own buttons: the default one drawn by macOS (accent, white title), the
/// keyboard focus visible, Escape and Return as on every Mac sheet.
@Suite(.serialized, .isolatedSettings) @MainActor struct ConflictDialogLookTests {
    private func dialog(newer: Bool, remaining: Int? = nil) -> ConflictDialog {
        let source = FileItem(
            url: URL(fileURLWithPath: "/fixture/src/a.txt"), name: "a.txt", isDirectory: false, size: 5,
            modificationDate: Date(timeIntervalSince1970: newer ? 300 : 100))
        let target = FileItem(
            url: URL(fileURLWithPath: "/fixture/dst/a.txt"), name: "a.txt", isDirectory: false, size: 3,
            modificationDate: Date(timeIntervalSince1970: 200))
        let d = ConflictDialog(
            info: ConflictInfo(source: source, destination: target, suggestedName: "a (1).txt", remainingConflicts: remaining), kind: .copy)
        d.window.isReleasedWhenClosed = false
        return d
    }

    private func buttons(_ d: ConflictDialog) -> [NSButton] {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return all(d.window.contentView!).compactMap { $0 as? NSButton }.filter { !Theme.isChoice($0) && !($0 is NSPopUpButton) }
    }

    @Test func buttonsAreAppKitsWithOneDefault() throws {
        for newer in [true, false] {
            let d = dialog(newer: newer)
            defer { d.window.close() }
            let all = buttons(d)
            // Plain NSButtons (no class of ours drawing them, so AppKit draws the focus ring), push bezels.
            #expect(all.allSatisfy { type(of: $0) == NSButton.self && $0.bezelStyle == .push })
            #expect(all.filter { $0.keyEquivalent == "\r" }.map(\.title) == [newer ? "Replace" : "Skip"])
            #expect(all.filter { $0.keyEquivalent == "\u{1b}" }.map(\.title) == ["Stop Copying"])
            let rules = try #require(all.first { $0.toolTip == "Conditional replacement rules" })
            #expect(rules.image != nil && rules.title.isEmpty && !rules.isHidden)
            // Nothing overlaps: each button's frame is clear of the others'.
            let shown = all.filter { !$0.isHidden && $0.frame.minY < 60 }.map(\.frame)
            for (i, a) in shown.enumerated() { for b in shown[(i + 1)...] { #expect(a.intersection(b).width <= 0) } }
        }
    }

    /// The rule's button shows its whole title ("Apply to All 120") beside the method pop-up, inside its strip.
    @Test(arguments: [nil, 2, 42, 120, 1200] as [Int?]) func applyToAllShowsItsWholeTitle(remaining: Int?) throws {
        let d = dialog(newer: true, remaining: remaining)
        defer { d.window.close() }
        let rule = try #require(buttons(d).first { $0.title.hasPrefix("Apply") })
        #expect(rule.title == ((remaining ?? 1) > 1 ? "Apply to All \(remaining ?? 1)" : "Apply"))
        let method = try #require(d.window.contentView?.subviews.first { $0 is NSPopUpButton })
        #expect(rule.frame.width >= rule.fittingSize.width, "\(rule.title) is cut")
        #expect(rule.frame.minX >= method.frame.maxX, "\(rule.title) overlaps the method pop-up")
        #expect(rule.frame.maxX <= 600, "\(rule.title) leaves its strip")
    }

    @Test func aPaletteThemeGivesTheDefaultButtonItsAccent() {
        Settings.shared.updateAppearance { $0.themeName = "Breeze Light" }
        let d = dialog(newer: true)
        defer { d.window.close() }
        Theme.dress(d.window)
        let replace = buttons(d).first { $0.keyEquivalent == "\r" }
        #expect(replace?.bezelColor?.usingColorSpace(.sRGB) == Theme.accent.usingColorSpace(.sRGB))
    }

    // MARK: Real events (AppKit's own dispatch: NSApp.sendEvent for keys)

    /// The sheet shown on its own, answering into `answers`.
    private func presented(newer: Bool, _ answers: @escaping (ConflictAnswer) -> Void) -> ConflictDialog {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let d = dialog(newer: newer)
        d.present(on: nil, completion: answers)
        d.window.orderFront(nil)
        return d
    }

    private func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
        NSApp.sendEvent(event)
    }

    /// Return is Replace for a newer item and Skip for an older one; Escape stops the transfer; ⌘D keeps both.
    @Test(arguments: [(true, ConflictResolution.overwrite), (false, .skip)])
    func returnAndEscapeAnswerAsTheirButtonsSay(newer: Bool, returnAnswer: ConflictResolution) throws {
        var answer: ConflictAnswer?
        let d = presented(newer: newer) { answer = $0 }
        defer { d.window.close() }
        try press(36, "\r", in: d.window)
        #expect(answer?.resolution == returnAnswer)

        answer = nil
        let e = presented(newer: newer) { answer = $0 }
        defer { e.window.close() }
        try press(53, "\u{1b}", in: e.window)
        #expect(answer?.resolution == .cancel)

        answer = nil
        let k = presented(newer: newer) { answer = $0 }
        defer { k.window.close() }
        try press(2, "d", .command, in: k.window)
        #expect(answer?.resolution == .keepBoth)
    }

    /// Each button gives its answer when pressed (performClick: a synthetic mouse-down through window.sendEvent ends
    /// the test process with status 0 under swift test, so the run silently stops).
    @Test(arguments: [("Skip", ConflictResolution.skip), ("Keep Both", .keepBoth), ("Replace", .overwrite), ("Stop Copying", .cancel)])
    func clickingAButtonAnswersWithIt(title: String, resolution: ConflictResolution) throws {
        var answer: ConflictAnswer?
        let d = presented(newer: true) { answer = $0 }
        defer { d.window.close() }
        let button = try #require(buttons(d).first { $0.title == title })
        button.performClick(nil)
        #expect(answer?.resolution == resolution)
    }
}
