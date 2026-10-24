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
    private func dialog(newer: Bool) -> ConflictDialog {
        let source = FileItem(
            url: URL(fileURLWithPath: "/fixture/src/a.txt"), name: "a.txt", isDirectory: false, size: 5,
            modificationDate: Date(timeIntervalSince1970: newer ? 300 : 100))
        let target = FileItem(
            url: URL(fileURLWithPath: "/fixture/dst/a.txt"), name: "a.txt", isDirectory: false, size: 3,
            modificationDate: Date(timeIntervalSince1970: 200))
        let d = ConflictDialog(info: ConflictInfo(source: source, destination: target, suggestedName: "a (1).txt"), kind: .copy)
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
            // The rule's button shows its whole title beside the method pop-up.
            let rule = try #require(all.first { $0.title.hasPrefix("Apply") })
            let method = try #require(d.window.contentView?.subviews.first { $0 is NSPopUpButton })
            #expect(rule.frame.width >= rule.fittingSize.width && rule.frame.minX >= method.frame.maxX)
        }
    }

    @Test func aPaletteThemeGivesTheDefaultButtonItsAccent() {
        Settings.shared.updateAppearance { $0.themeName = "Breeze Light" }
        let d = dialog(newer: true)
        defer { d.window.close() }
        Theme.dress(d.window)
        let replace = buttons(d).first { $0.keyEquivalent == "\r" }
        #expect(replace?.bezelColor?.usingColorSpace(.sRGB) == Theme.accent.usingColorSpace(.sRGB))
    }
}
