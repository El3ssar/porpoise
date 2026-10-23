import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let shift = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let control = Self(rawValue: 8)
}
public struct KeyboardShortcut: Codable, Sendable, Hashable {
    public var key: String
    public var modifiers: ShortcutModifiers
    public init(key: String = "", modifiers: ShortcutModifiers = []) { self.key = key; self.modifiers = modifiers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        modifiers = try c.decodeIfPresent(ShortcutModifiers.self, forKey: .modifiers) ?? []
    }
    public var isEmpty: Bool { key.isEmpty }
    /// AppKit infers Shift for uppercase letters and shifted ASCII symbols in default key equivalents.
    public var normalized: Self {
        guard !key.isEmpty else { return Self() }
        let shifted = Array("~!@#$%^&*()_+{}|:\"<>?")
        let base = Array("`1234567890-=[]\\;',./")
        if let character = key.first, key.count == 1, let index = shifted.firstIndex(of: character) {
            return Self(key: String(base[index]), modifiers: modifiers.union(.shift))
        }
        let lower = key.lowercased()
        let impliedShift: ShortcutModifiers = key != lower ? .shift : []
        return Self(key: lower, modifiers: modifiers.union(impliedShift))
    }
    public func validate() throws {
        guard (key.isEmpty || key.unicodeScalars.count == 1), !key.contains("\0"), modifiers.rawValue >= 0, modifiers.rawValue & ~15 == 0 else {
            throw ShortcutError.invalid("A shortcut must contain one key and valid modifiers.")
        }
        // A plain letter (or Return, Tab…) would fire while typing anywhere.
        guard key.isEmpty || !modifiers.intersection([.command, .control, .option]).isEmpty || isFunctionOrNavigationKey else {
            throw ShortcutError.invalid("A shortcut needs ⌘, ⌃ or ⌥, unless it is a function or navigation key.")
        }
    }

    /// F1–F35, arrows, Home, End, Page Up/Down, Forward Delete.
    public var isFunctionOrNavigationKey: Bool {
        guard let v = key.unicodeScalars.first?.value, key.unicodeScalars.count == 1 else { return false }
        return (0xf700...0xf726).contains(v) || (0xf728...0xf72d).contains(v)
    }
    public var display: String {
        guard !key.isEmpty else { return "—" }
        // A shifted symbol shows as typed, as menus do (⌘?, not ⇧⌘/); letters and other keys show ⇧.
        let shortcut = key.count == 1 && "~!@#$%^&*()_+{}|:\"<>?".contains(key) ? self : normalized
        let flags = shortcut.modifiers
        let prefix =
            (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "")
        let special = [
            "\r": "↩", "\t": "⇥", "\u{8}": "⌫", "\u{7f}": "⌫", "\u{1b}": "Esc", " ": "Space", "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←",
            "\u{f703}": "→", "\u{f728}": "⌦", "\u{f729}": "Home", "\u{f72b}": "End", "\u{f72c}": "Page Up", "\u{f72d}": "Page Down",
        ]
        let scalar = shortcut.key.unicodeScalars.first!.value
        let label = special[shortcut.key] ?? ((0xf704...0xf726).contains(scalar) ? "F\(scalar - 0xf703)" : shortcut.key.uppercased())
        return prefix + label
    }
}
public enum ShortcutError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
/// The default shortcuts every action starts from, before the user's own bindings: Finder's, or Dolphin's (Ctrl → ⌘),
/// which versions before 0.9.2 used.
public enum ShortcutKeySet: String, Codable, CaseIterable, Sendable {
    case mac, dolphin
    public var title: String { self == .mac ? "Mac (Finder)" : "Dolphin" }
}
public struct ShortcutAction: Sendable {
    public let id: String
    public let title: String
    public let defaults: [KeyboardShortcut]
    public init(id: String, title: String, defaults: [KeyboardShortcut]) { self.id = id; self.title = title; self.defaults = defaults }
}
public struct ShortcutConflict: Sendable, Equatable {
    public let first: String
    public let second: String
    public let shortcut: KeyboardShortcut
}
public struct ShortcutPreferences: Codable, Sendable, Equatable {
    public var version = 1
    /// An empty shortcut disables all default equivalents (including hidden aliases) for that action.
    public var overrides: [String: KeyboardShortcut] = [:]
    public init() {}
    /// Hand-written files may leave out the version or a shortcut's modifiers.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        overrides = try c.decodeIfPresent([String: KeyboardShortcut].self, forKey: .overrides) ?? [:]
    }
    public func validate() throws {
        guard version == 1, overrides.keys.allSatisfy({ !$0.isEmpty && $0.count <= 2048 }) else {
            throw ShortcutError.invalid("Unsupported shortcut file or invalid action identifier.")
        }
        for value in overrides.values { try value.validate() }
    }
    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    public func encoded() throws -> Data {
        try validate(); let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(self)
    }
    /// Clashes the user's own bindings cause. Two built-in defaults sharing a key (menus the system fills in) are
    /// not the user's to resolve, and never block their changes.
    public func conflicts(actions: [ShortcutAction]) -> [ShortcutConflict] {
        var used: [KeyboardShortcut: String] = [:], conflicts: [ShortcutConflict] = []
        for action in actions.sorted(by: { $0.id < $1.id }) {
            let shortcuts = overrides[action.id].map { [$0] } ?? action.defaults
            for shortcut in shortcuts where !shortcut.isEmpty {
                let normalized = shortcut.normalized
                if let owner = used[normalized], owner != action.id {
                    guard overrides[owner] != nil || overrides[action.id] != nil else { continue }
                    conflicts.append(ShortcutConflict(first: owner, second: action.id, shortcut: normalized))
                } else {
                    used[normalized] = action.id
                }
            }
        }
        return conflicts
    }
}

/// Identifiers shared by the native customization palette and the custom unified toolbar.
public enum ToolbarCommand: String, Codable, CaseIterable, Sendable {
    case back, forward, up, viewMode, location, split, search, menu, reload, newTab, terminal, commandPalette, link, customTools
    public var title: String {
        switch self {
        case .back: return "Back"
        case .forward: return "Forward"
        case .up: return "Up"
        case .viewMode: return "View Mode"
        case .location: return "Location"
        case .split: return "Split"
        case .search: return "Search"
        case .menu: return "Menu"
        case .reload: return "Reload"
        case .newTab: return "New Tab"
        case .terminal: return "Terminal"
        case .commandPalette: return "Command Palette"
        case .link: return "Linked Browsing"
        case .customTools: return "Custom Tools"
        }
    }
    public static let defaults: [Self] = [.back, .forward, .up, .viewMode, .location, .split, .search, .menu]
    public static func validate(_ commands: [Self]) throws {
        guard commands.contains(.location), Set(commands).count == commands.count else {
            throw ShortcutError.invalid("The toolbar needs one Location item and no duplicate actions.")
        }
    }
}
