import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Clicks, Shift and Cmd and moves of the current item, which the folder view and the Applications grid share.
@MainActor struct ItemSelectionControllerTests {
    let scratch: Scratch

    init() throws {
        scratch = try Scratch()
        for name in ["a", "b", "c", "d", "e"] { try scratch.file("\(name).txt") }
    }

    private func model() async throws -> DirectoryModel {
        let m = try await DirectoryModel.loaded(scratch.url)
        try #require(m.rowNames == ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"])
        return m
    }

    private func names(_ m: DirectoryModel) -> [String] { m.selection.map(\.lastPathComponent).sorted() }

    @Test func shiftClicksSelectFromTheAnchorNotTheCurrentItem() async throws {
        let m = try await model(), s = ItemSelectionController(model: m)
        s.click(1, modifiers: [])
        s.contextClick(3)  // current, not the anchor
        s.click(4, modifiers: .shift)
        #expect(names(m) == ["b.txt", "c.txt", "d.txt", "e.txt"])
        s.click(0, modifiers: .command)  // Cmd moves the anchor
        s.click(2, modifiers: [.command, .shift])
        #expect(names(m) == ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"])
        #expect(m.currentURL?.lastPathComponent == "c.txt")
    }

    @Test func aPlainClickOnOneOfSeveralSelectedLeavesOnlyIt() async throws {
        let m = try await model(), s = ItemSelectionController(model: m)
        s.click(0, modifiers: []); s.click(2, modifiers: .shift)
        s.click(1, modifiers: [])  // already selected: the selection stays until the click ends
        #expect(names(m) == ["a.txt", "b.txt", "c.txt"])
        s.clickEnded(1, wasSelected: true)
        #expect(names(m) == ["b.txt"] && m.anchorURL?.lastPathComponent == "b.txt")
        s.clickBackground(modifiers: .shift)
        #expect(names(m) == ["b.txt"])
        s.clickBackground(modifiers: [])
        #expect(m.selection.isEmpty)
    }

    @Test func shiftMovesSelectTheRangeFromTheAnchor() async throws {
        let m = try await model(), s = ItemSelectionController(model: m)
        s.move(to: 1, extend: false)
        s.move(to: 3, extend: true)
        #expect(names(m) == ["b.txt", "c.txt", "d.txt"])
        s.move(to: 2, extend: true)  // back toward the anchor: the range shrinks
        #expect(names(m) == ["b.txt", "c.txt"])
        s.toggle(m.rows[4].item.url)
        #expect(names(m) == ["b.txt", "c.txt", "e.txt"] && m.anchorURL?.lastPathComponent == "e.txt")
    }

    /// The Applications grid moves as the folder view does: Shift+arrow selects a range (it only added the item it
    /// reached, so going back kept it), and Home and End go to the first and last app.
    @Test func theAppsGridMovesWithTheSameRules() async throws {
        let m = try await model()
        let grid = AppsGridView(model: m)
        grid.frame = CGRect(x: 0, y: 0, width: 100, height: 2000)
        grid.updateLayout(width: 100)  // one column: ↓ is the next app
        func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            grid.keyDown(
                with: NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil, characters: "",
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        }
        key(125)
        #expect(names(m) == ["a.txt"])
        key(125, .shift); key(125, .shift)
        #expect(names(m) == ["a.txt", "b.txt", "c.txt"])
        key(126, .shift)
        #expect(names(m) == ["a.txt", "b.txt"])
        key(119)
        #expect(names(m) == ["e.txt"] && m.currentURL?.lastPathComponent == "e.txt")
        key(115, .shift)
        #expect(names(m) == ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"])
        key(119); key(116)  // Page Up: everything is shown, so to the first
        #expect(names(m) == ["a.txt"])
    }
}
