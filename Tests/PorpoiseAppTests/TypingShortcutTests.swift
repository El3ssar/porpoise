import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Shortcuts that change files (⌘⌫, ⌘D, ⌘E…) never fire while a field or the terminal is being typed in.
@MainActor struct TypingShortcutTests {
    private func key(_ c: String, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil, characters: c,
            charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
    }

    @Test(.isolatedSettings) func fileCommandsLeaveTheirKeysToTheFieldBeingTyped() throws {
        _ = NSApplication.shared
        let menu = AppDelegate.shared.buildMainMenu()
        func items(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let all = items(menu)
        func shortcut(_ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) throws -> NSMenuItem {
            try #require(all.first { $0.action == action && $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mods })
        }
        typealias W = MainWindowController
        // ⌫ arrives as DEL; the menus spell it as backspace.
        let trash = try shortcut(#selector(W.moveToTrash(_:)), KeyEquivalent.backspace, .command)
        #expect(W.typingKeeps(trash, key("\u{7f}", .command)))
        let deleteNow = try shortcut(#selector(W.deleteItem(_:)), KeyEquivalent.backspace, [.command, .option])
        #expect(W.typingKeeps(deleteNow, key("\u{7f}", [.command, .option])))
        // ⌦ alone trashes only with Dolphin's keys.
        Settings.shared.shortcutKeySet = .dolphin
        let forwardTrash = try #require(
            items(AppDelegate.shared.buildMainMenu()).first {
                $0.action == #selector(W.moveToTrash(_:)) && $0.keyEquivalent == KeyEquivalent.forwardDelete && $0.keyEquivalentModifierMask == []
            })
        #expect(W.typingKeeps(forwardTrash, key(KeyEquivalent.forwardDelete, .function)))
        for (action, k, mods) in [
            (#selector(W.duplicateItem(_:)), "d", NSEvent.ModifierFlags.command), (#selector(W.ejectVolume(_:)), "e", .command),
            (#selector(W.makeAlias(_:)), "a", [.command, .control]), (#selector(W.newFolderWithSelection(_:)), "n", [.command, .control]),
        ] {
            #expect(W.typingKeeps(try shortcut(action, k, mods), key(k, mods)), "\(action)")
        }
        // Only for the key pressed: ⌘D doesn't hold back Move to Trash, and other ⌘ shortcuts still work while typing.
        #expect(!W.typingKeeps(trash, key("d", .command)))
        let newTab = try #require(all.first { $0.keyEquivalent == "t" && $0.keyEquivalentModifierMask == .command })
        #expect(!W.typingKeeps(newTab, key("t", .command)))
    }

    @Test func backspaceMatchesTheMenuSpelling() {
        #expect(KeyEquivalent.matches(KeyEquivalent.backspace, typed: "\u{7f}"))
        #expect(KeyEquivalent.matches("d", typed: "D") && !KeyEquivalent.matches("d", typed: "e"))
        #expect(!KeyEquivalent.matches("", typed: "") && !KeyEquivalent.matches("d", typed: nil))
    }
}
