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
@MainActor final class MenuCommandRegistry {
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
    /// The bindings applied to AppKit, in primary/alias order, before any presentation reads them back.
    private(set) var dispatchBindings: [String: [KeyboardShortcut]] = [:]
    private var blockedOverrides: Set<String> = []
    func shortcut(for id: String) -> KeyboardShortcut { dispatchBindings[id]?.first ?? KeyboardShortcut() }
    func shortcut(for action: Selector, tag: Int = 0) -> KeyboardShortcut {
        shortcut(for: NSStringFromSelector(action) + "#\(tag)#")
    }
    var shortcutActions: [ShortcutAction] {
        shortcutActions(tools: Settings.shared.customTools)
    }
    private func shortcutActions(tools: [CustomTool]) -> [ShortcutAction] {
        commands.map(\.definition)
            + tools.map {
                ShortcutAction(id: "customTool:" + $0.id.uuidString, title: $0.name, defaults: [$0.shortcut])
            }
    }
    var appKitBindings: [KeyboardShortcut] {
        var result: [KeyboardShortcut] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                if Self.isAppKits(item), !item.keyEquivalent.isEmpty {
                    result.append(KeyboardShortcut(key: item.keyEquivalent, modifiers: ShortcutModifiers(item.keyEquivalentModifierMask)))
                }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu) }
        return result
    }
    private var observer: NSObjectProtocol?

    func start() {
        refresh(fillDynamic: false)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let key = note.object as? String
                // The key set decides the menu items' own keys (and which hidden alternates exist): build the menu bar again.
                if note.object == nil || key == "shortcutKeySet" || key == "customTools" { NSApp.mainMenu = AppDelegate.shared.buildMainMenu() }
                if note.object == nil || key == "keyboardShortcuts" || key == "shortcutKeySet" || key == "customTools" {
                    self?.refresh(fillDynamic: false)
                }
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    static func id(_ item: NSMenuItem) -> String {
        NSStringFromSelector(item.action!) + "#" + String(item.tag) + "#" + ((item.representedObject as? String) ?? "")
    }
    func refresh(fillDynamic: Bool = true) {
        guard let menu = NSApp.mainMenu else { return }
        originals = originals.filter { $0.value.item != nil }
        var grouped: [String: [(NSMenuItem, String)]] = [:], order: [String] = []
        @MainActor func walk(_ menu: NSMenu, path: [String]) {
            if fillDynamic, ["Sort By", "Group By", "Show Additional Information", "Places", "Tags"].contains(menu.title) {
                menu.delegate?.menuNeedsUpdate?(menu)
            }
            menu.update()
            for item in menu.items where !item.isSeparatorItem {
                // The Services menu is the system's (its items share one action and carry other apps' shortcuts).
                if let submenu = item.submenu {
                    if submenu !== NSApp.servicesMenu { walk(submenu, path: path + [item.title]) }
                    continue
                }
                guard item.action != nil, item.action != #selector(MainWindowController.runCustomTool(_:)), !Self.isAppKits(item) else { continue }
                let id = Self.id(item)
                if grouped[id] == nil { order.append(id) }
                grouped[id, default: []].append((item, (path + [item.title]).joined(separator: " › ")))
                let identity = ObjectIdentifier(item)
                if originals[identity]?.item !== item { originals[identity] = Original(item) }
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
    /// Items AppKit adds and manages itself: private actions, the window list, and the fn-key window items (Fill,
    /// Center…), whose modifiers can't be stored here and must keep their own keys.
    static func isAppKits(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        return NSStringFromSelector(action).hasPrefix("_") || action == #selector(NSWindow.makeKeyAndOrderFront(_:))
            || item.keyEquivalentModifierMask.contains(.function)
    }

    func apply() {
        let preferences = Settings.shared.keyboardShortcuts
        blockedOverrides = Set(
            preferences.conflicts(actions: shortcutActions(tools: Settings.shared.customToolsIfLoaded)).flatMap { [$0.first, $0.second] })
        dispatchBindings = [:]
        for command in commands {
            let items = [command.item] + command.aliases
            let defaults = items.map { originals[ObjectIdentifier($0)]?.shortcut ?? KeyboardShortcut() }
            let bindings: [KeyboardShortcut]
            if let override = preferences.overrides[command.id], !blockedOverrides.contains(command.id) {
                bindings = [override.normalized] + Array(repeating: KeyboardShortcut(), count: command.aliases.count)
            } else {
                bindings = defaults
            }
            dispatchBindings[command.id] = bindings
            for (item, binding) in zip(items, bindings) {
                item.keyEquivalent = binding.key; item.keyEquivalentModifierMask = binding.modifiers.appKit
            }
        }
    }

    /// Dynamic menu items are rebuilt when their menu opens; apply saved keys to those fresh instances too.
    func apply(to menu: NSMenu) {
        let preferences = Settings.shared.keyboardShortcuts
        @MainActor func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard item.action != nil, item.action != #selector(MainWindowController.runCustomTool(_:)), !Self.isAppKits(item) else { continue }
                let identity = ObjectIdentifier(item)
                if originals[identity]?.item !== item { originals[identity] = Original(item) }
                // A modifier-only popup alternate uses its mask to reveal another item, not as a shortcut.
                if item.isAlternate && item.keyEquivalent.isEmpty { continue }
                let id = Self.id(item)
                let value: KeyboardShortcut
                if let bindings = dispatchBindings[id] {
                    value = item.isHidden ? KeyboardShortcut() : (bindings.first ?? KeyboardShortcut())
                } else if let override = preferences.overrides[id], !blockedOverrides.contains(id) {
                    value = item.isHidden ? KeyboardShortcut() : override.normalized
                } else {
                    value = originals[identity]?.shortcut ?? KeyboardShortcut()
                }
                item.keyEquivalent = value.key; item.keyEquivalentModifierMask = value.modifiers.appKit
            }
        }
        walk(menu)
    }

    /// Whether a menu bar item has `shortcut` now (the key set's default or the user's binding).
    func isBound(_ shortcut: KeyboardShortcut) -> Bool {
        let wanted = shortcut.normalized
        return dispatchBindings.values.contains { $0.contains { !$0.isEmpty && $0.normalized == wanted } }
    }

    /// The menu item `shortcut` runs now (the key set's default or the user's binding), if any.
    func item(bound shortcut: KeyboardShortcut) -> NSMenuItem? {
        let wanted = shortcut.normalized
        for command in commands {
            guard let bindings = dispatchBindings[command.id],
                let i = bindings.firstIndex(where: { !$0.isEmpty && $0.normalized == wanted })
            else { continue }
            return ([command.item] + command.aliases)[safe: i]
        }
        return nil
    }

    /// View-local compatibility shortcuts must stop firing when their menu action is rebound or disabled.
    func fallbackAllowed(_ selector: Selector, tag: Int = 0) -> Bool {
        let prefix = NSStringFromSelector(selector) + "#\(tag)#"
        return !Settings.shared.keyboardShortcuts.overrides.keys.contains { $0.hasPrefix(prefix) && !blockedOverrides.contains($0) }
    }
    static func enabled(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, let target = NSApp.target(forAction: action, to: item.target, from: item) else { return false }
        if let validation = target as? NSMenuItemValidation { return validation.validateMenuItem(item) }
        if let validation = target as? NSUserInterfaceValidations { return validation.validateUserInterfaceItem(item) }
        return item.isEnabled
    }
}
