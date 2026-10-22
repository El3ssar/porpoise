import AppKit

// Menu item helpers, shared by the menu bar, the hamburger and context menus.

/// Key equivalents for the special keys AppKit spells as private-use characters.
enum KeyEquivalent {
    /// Function key F`n` (F1…F35).
    static func f(_ n: Int) -> String { character(NSF1FunctionKey + n - 1) }
    static let up = character(NSUpArrowFunctionKey)
    static let down = character(NSDownArrowFunctionKey)
    static let left = character(NSLeftArrowFunctionKey)
    static let right = character(NSRightArrowFunctionKey)
    static let home = character(NSHomeFunctionKey)
    static let pageUp = character(NSPageUpFunctionKey)
    static let pageDown = character(NSPageDownFunctionKey)
    /// The forward-delete key (fn+⌫).
    static let forwardDelete = character(NSDeleteFunctionKey)
    /// ⌫ (backspace).
    static let backspace = "\u{8}"

    private static func character(_ code: Int) -> String { String(utf16CodeUnits: [unichar(code)], count: 1) }

    /// Whether a key press typed `typed` (its charactersIgnoringModifiers) for the shortcut `key`. ⌫ types DEL
    /// (`\u{7f}`), while a menu spells it `\u{8}`.
    static func matches(_ key: String, typed: String?) -> Bool {
        func normalized(_ s: String) -> String { s == "\u{7f}" ? backspace : s.lowercased() }
        guard !key.isEmpty, let typed else { return false }
        return normalized(typed) == normalized(key)
    }

    /// The arrows, Home, End, Page Up and Page Down: with or without ⌘ they move the insertion point in a text field
    /// (⌘← to the line's start), so a shortcut on them must not fire while one is edited.
    static func movesInText(_ key: String) -> Bool {
        guard let u = key.utf16.first else { return false }
        return [
            NSUpArrowFunctionKey, NSDownArrowFunctionKey, NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSHomeFunctionKey,
            NSEndFunctionKey, NSPageUpFunctionKey, NSPageDownFunctionKey,
        ].contains(Int(u))
    }

    /// F1…F12: keys that never type text, so they may fire while a text field has focus.
    static func isFunctionKey(_ key: String) -> Bool {
        guard let u = key.utf16.first else { return false }
        return Int(u) >= NSF1FunctionKey && Int(u) <= NSF12FunctionKey
    }
}

extension NSMenuItem {
    /// One factory for every menu in the app, so items look and behave the same everywhere.
    static func make(
        _ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = .command,
        icon: String? = nil, tag: Int = 0, obj: Any? = nil
    ) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.tag = tag
        it.representedObject = obj
        if let icon { it.image = Icons.shared.menuIcon(icon) }
        return it
    }

    /// A submenu host item.
    static func submenu(_ title: String, icon: String?, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        if let icon { it.image = Icons.shared.menuIcon(icon) }
        return it
    }

    /// Extra key equivalents for the same action (hidden, shortcut still works).
    func hiddenAlternate() -> NSMenuItem {
        isHidden = true
        allowsKeyEquivalentWhenHidden = true
        return self
    }
}
