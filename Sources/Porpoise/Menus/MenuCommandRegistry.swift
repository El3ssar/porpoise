import AppKit
import PorpoiseCore
import PorpoiseServices

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }; if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }; if flags.contains(.control) { insert(.control) }
    }
    var appKit: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }; if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }; if contains(.control) { flags.insert(.control) }
        return flags
    }
}

/// Stable action IDs use selectors, tags and represented values, independent of translated/dynamic titles.
final class MenuCommandRegistry {
    static let shared = MenuCommandRegistry()
    struct Command {
        let id: String
        let title: String
        let path: String
        let item: NSMenuItem
        let aliases: [NSMenuItem]
        let defaults: [KeyboardShortcut]
        var definition: ShortcutAction { ShortcutAction(id: id, title: path, defaults: defaults) }
    }
    private final class Original {
        weak var item: NSMenuItem?
        let shortcut: KeyboardShortcut
        init(_ item: NSMenuItem) {
            self.item = item; shortcut = KeyboardShortcut(key: item.keyEquivalent, modifiers: ShortcutModifiers(item.keyEquivalentModifierMask))
        }
    }
    private var originals: [ObjectIdentifier: Original] = [:]
    private(set) var commands: [Command] = []
    private var observer: NSObjectProtocol?

    func start() {
        refresh(fillDynamic: false)
        observer = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] note in
            if note.object == nil || note.object as? String == "keyboardShortcuts" { self?.refresh(fillDynamic: false) }
        }
    }
    static func id(_ item: NSMenuItem) -> String {
        NSStringFromSelector(item.action!) + "#" + String(item.tag) + "#" + ((item.representedObject as? String) ?? "")
    }
    func refresh(fillDynamic: Bool = true) {
        guard let menu = NSApp.mainMenu else { return }
        originals = originals.filter { $0.value.item != nil }
        var grouped: [String: [(NSMenuItem, String)]] = [:], order: [String] = []
        func walk(_ menu: NSMenu, path: [String]) {
            if fillDynamic, ["Sort By", "Group By", "Show Additional Information", "Places"].contains(menu.title) {
                menu.delegate?.menuNeedsUpdate?(menu)
            }
            menu.update()
            for item in menu.items where !item.isSeparatorItem {
                if let submenu = item.submenu { walk(submenu, path: path + [item.title]); continue }
                guard item.action != nil else { continue }
                let id = Self.id(item)
                if grouped[id] == nil { order.append(id) }
                grouped[id, default: []].append((item, (path + [item.title]).joined(separator: " › ")))
                let identity = ObjectIdentifier(item)
                if originals[identity] == nil { originals[identity] = Original(item) }
            }
        }
        walk(menu, path: [])
        commands = order.compactMap { id in
            guard let items = grouped[id], let primary = items.first(where: { !$0.0.isHidden }) ?? items.first else { return nil }
            return Command(
                id: id, title: primary.0.title, path: primary.1, item: primary.0, aliases: items.map(\.0).filter { $0 !== primary.0 },
                defaults: items.compactMap { originals[ObjectIdentifier($0.0)]?.shortcut }.filter { !$0.isEmpty })
        }
        apply()
    }
    func apply() {
        let preferences = Settings.shared.keyboardShortcuts
        guard preferences.conflicts(actions: commands.map(\.definition)).isEmpty else { return }
        for command in commands {
            let items = [command.item] + command.aliases
            if let override = preferences.overrides[command.id] {
                for (index, item) in items.enumerated() {
                    let value = index == 0 ? override.normalized : KeyboardShortcut()
                    item.keyEquivalent = value.key; item.keyEquivalentModifierMask = value.modifiers.appKit
                }
            } else {
                for item in items {
                    guard let original = originals[ObjectIdentifier(item)] else { continue }
                    item.keyEquivalent = original.shortcut.key; item.keyEquivalentModifierMask = original.shortcut.modifiers.appKit
                }
            }
        }
    }
    /// Dynamic menu items are rebuilt when their menu opens; apply saved keys to those fresh instances too.
    func apply(to menu: NSMenu) {
        let preferences = Settings.shared.keyboardShortcuts
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard item.action != nil else { continue }
                let identity = ObjectIdentifier(item)
                if originals[identity] == nil { originals[identity] = Original(item) }
                if let shortcut = preferences.overrides[Self.id(item)] {
                    let value = item.isHidden ? KeyboardShortcut() : shortcut.normalized
                    item.keyEquivalent = value.key; item.keyEquivalentModifierMask = value.modifiers.appKit
                }
            }
        }
        walk(menu)
    }

    /// View-local compatibility shortcuts must stop firing when their menu action is rebound or disabled.
    func fallbackAllowed(_ selector: Selector, tag: Int = 0) -> Bool {
        let prefix = NSStringFromSelector(selector) + "#\(tag)#"
        return !Settings.shared.keyboardShortcuts.overrides.keys.contains { $0.hasPrefix(prefix) }
    }
    static func enabled(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, let target = NSApp.target(forAction: action, to: item.target, from: item) else { return false }
        if let validation = target as? NSMenuItemValidation { return validation.validateMenuItem(item) }
        if let validation = target as? NSUserInterfaceValidations { return validation.validateUserInterfaceItem(item) }
        return item.isEnabled
    }
}
