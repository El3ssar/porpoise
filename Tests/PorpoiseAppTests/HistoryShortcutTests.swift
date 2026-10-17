import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// ⌘← / ⌘→ go Back and Forward like ⌘[ / ⌘], but never take those keys from a text field being edited.
@MainActor struct HistoryShortcutTests {
    private func key(_ code: Int, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        let c = String(utf16CodeUnits: [unichar(code)], count: 1)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil, characters: c,
            charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
    }

    @Test func commandArrowsGoBackAndForwardButNotWhileTyping() throws {
        _ = NSApplication.shared
        let menu = AppDelegate.shared.buildMainMenu()
        func items(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let all = items(menu)
        func shortcut(_ action: Selector, _ key: String) -> NSMenuItem? {
            all.first { $0.action == action && $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command }
        }
        let back = try #require(shortcut(#selector(MainWindowController.goBack(_:)), KeyEquivalent.left))
        let forward = try #require(shortcut(#selector(MainWindowController.goForward(_:)), KeyEquivalent.right))
        #expect(shortcut(#selector(MainWindowController.goBack(_:)), "[") != nil && back.allowsKeyEquivalentWhenHidden)
        #expect(shortcut(#selector(MainWindowController.goForward(_:)), "]") != nil && forward.allowsKeyEquivalentWhenHidden)
        let up = try #require(shortcut(#selector(MainWindowController.goUp(_:)), KeyEquivalent.up))

        // In a field (rename, location bar, search, filter), the arrows keep moving the insertion point.
        let cmdLeft = key(NSLeftArrowFunctionKey, .command), cmdRight = key(NSRightArrowFunctionKey, .command)
        #expect(MainWindowController.typingKeeps(back, cmdLeft) && MainWindowController.typingKeeps(forward, cmdRight))
        #expect(MainWindowController.typingKeeps(up, key(NSUpArrowFunctionKey, .command)))
        // Only for the key pressed; ⌘[ still works there, as before, and so does any other ⌘ shortcut.
        #expect(!MainWindowController.typingKeeps(back, cmdRight) && !MainWindowController.typingKeeps(forward, cmdLeft))
        let bracket = try #require(shortcut(#selector(MainWindowController.goBack(_:)), "["))
        let c = "[",
            bracketEvent = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: c,
                charactersIgnoringModifiers: c, isARepeat: false, keyCode: 33)!
        #expect(!MainWindowController.typingKeeps(bracket, bracketEvent))
        #expect(KeyEquivalent.movesInText(KeyEquivalent.home) && !KeyEquivalent.movesInText("a") && !KeyEquivalent.movesInText(""))
    }
}
