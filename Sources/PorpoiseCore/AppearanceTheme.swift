import Foundation

/// Portable sRGB colour, encoded as #RRGGBB. Invalid input is rejected before it reaches the UI.
public struct ThemeColor: Codable, Equatable, Sendable {
    public let red: Int
    public let green: Int
    public let blue: Int
    public init(_ red: Int, _ green: Int, _ blue: Int) {
        self.red = min(255, max(0, red)); self.green = min(255, max(0, green)); self.blue = min(255, max(0, blue))
    }
    public init(hex: String) throws {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, h.allSatisfy({ $0.isHexDigit }), let n = Int(h, radix: 16) else { throw AppearanceError.invalidColor(hex) }
        self.init((n >> 16) & 255, (n >> 8) & 255, n & 255)
    }
    public var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }
    public init(from decoder: Decoder) throws { try self.init(hex: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(hex) }
}

public enum AppearanceError: Error, LocalizedError {
    case invalidColor(String), invalidTheme, invalidTerminalScheme, invalidTemplate
    public var errorDescription: String? {
        switch self {
        case .invalidColor(let c): return "Invalid colour: \(c). Use #RRGGBB."
        case .invalidTheme: return "The theme must contain every colour role and 16 terminal colours."
        case .invalidTerminalScheme: return "The terminal scheme has invalid or missing colour components."
        case .invalidTemplate: return "The terminal command must contain bare {dir}, outside quotes and without a dollar sign or backslash."
        }
    }
}

public enum ThemeRole: String, CaseIterable, Codable, Sendable {
    case windowBackground, viewBackground, alternateRow, selection, selectionText, text, secondaryText, accent
    case panel, sidebar, hover, folderTint
    public var title: String {
        switch self {
        case .windowBackground: return "Window background"
        case .viewBackground: return "View background"
        case .alternateRow: return "Alternate rows"
        case .selection: return "Selection"
        case .selectionText: return "Selected text"
        case .text: return "Text"
        case .secondaryText: return "Secondary text"
        case .accent: return "Accent"
        case .panel: return "Panel"
        case .sidebar: return "Places sidebar"
        case .hover: return "Hover"
        case .folderTint: return "Folder tint"
        }
    }
}

public struct AppearanceTheme: Codable, Equatable, Sendable {
    public var name: String
    public var isDark: Bool
    public var colors: [String: ThemeColor]
    public var terminalPalette: [ThemeColor]
    private init(name: String, isDark: Bool, background: String, view: String, text: String, accent: String, secondary: String) {
        self.name = name; self.isDark = isDark
        let bg = try! ThemeColor(hex: background), fg = try! ThemeColor(hex: text), ac = try! ThemeColor(hex: accent)
        colors = Dictionary(uniqueKeysWithValues: ThemeRole.allCases.map { ($0.rawValue, bg) })
        colors[ThemeRole.viewBackground.rawValue] = try! ThemeColor(hex: view)
        for r in [ThemeRole.text, .selectionText] { colors[r.rawValue] = fg }
        for r in [ThemeRole.selection, .accent, .folderTint] { colors[r.rawValue] = ac }
        colors[ThemeRole.secondaryText.rawValue] = try! ThemeColor(hex: secondary)
        colors[ThemeRole.hover.rawValue] = fg
        terminalPalette = (isDark ? KonsoleScheme.builtInDesertPalette : KonsoleScheme.light.palette).map { ThemeColor($0.0, $0.1, $0.2) }
        terminalPalette[0] = bg; terminalPalette[7] = fg; terminalPalette[4] = ac
        if let ansi = Self.ansiPalettes[name] { terminalPalette = ansi.split(separator: " ").map { try! ThemeColor(hex: String($0)) } }
        if name == "Breeze Light" {
            self[.alternateRow] = ThemeColor(244, 245, 249)
            self[.selection] = ThemeColor(66, 132, 210)
            self[.selectionText] = ThemeColor(26, 30, 44)
        } else if name == "Breeze Dark" {
            self[.selection] = ThemeColor(71, 99, 130)
        } else if name == "High Contrast" {
            self[.selectionText] = ThemeColor(0, 0, 0)
        }
    }
    public subscript(_ role: ThemeRole) -> ThemeColor {
        get { colors[role.rawValue] ?? ThemeColor(0, 0, 0) }
        set { colors[role.rawValue] = newValue }
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            ThemeRole.allCases.allSatisfy({ colors[$0.rawValue] != nil }), terminalPalette.count == 16
        else { throw AppearanceError.invalidTheme }
    }
    public static func decode(_ data: Data) throws -> Self {
        let theme = try JSONDecoder().decode(Self.self, from: data); try theme.validate(); return theme
    }
    public func encoded() throws -> Data {
        try validate(); let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(self)
    }

    /// KDE colour groups. Unknown groups are ignored; missing roles retain the matching Breeze defaults.
    public static func kde(_ text: String, name: String = "Imported KDE theme") throws -> Self {
        var section = "", values: [String: ThemeColor] = [:], title = name
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = String(line.dropFirst().dropLast()); continue }
            guard !line.hasPrefix("#"), !line.hasPrefix(";"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if section == "General", key == "Name", !value.isEmpty { title = value }
            guard section.hasPrefix("Colors:") else { continue }
            let parts = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 3, parts.prefix(3).allSatisfy({ (0...255).contains($0) }) else { continue }
            values[section + "/" + key] = ThemeColor(parts[0], parts[1], parts[2])
        }
        guard let background = values["Colors:Window/BackgroundNormal"] ?? values["Colors:View/BackgroundNormal"] else {
            throw AppearanceError.invalidTheme
        }
        var theme = builtIns[(background.red + background.green + background.blue) < 384 ? 1 : 0]
        theme.name = title
        let mapping: [(ThemeRole, String)] = [
            (.windowBackground, "Window/BackgroundNormal"), (.panel, "Window/BackgroundNormal"), (.sidebar, "Window/BackgroundNormal"),
            (.text, "View/ForegroundNormal"), (.secondaryText, "View/ForegroundInactive"), (.viewBackground, "View/BackgroundNormal"),
            (.alternateRow, "View/BackgroundAlternate"), (.selection, "Selection/BackgroundNormal"), (.selectionText, "Selection/ForegroundNormal"),
            (.accent, "Selection/BackgroundNormal"), (.hover, "View/DecorationHover"), (.folderTint, "Selection/BackgroundNormal"),
        ]
        for (role, key) in mapping { if let color = values["Colors:" + key] { theme[role] = color } }
        return theme
    }

    private static let ansiPalettes: [String: String] = [
        "Nord": "3b4252 bf616a a3be8c ebcb8b 81a1c1 b48ead 88c0d0 e5e9f0 4c566a bf616a a3be8c ebcb8b 81a1c1 b48ead 8fbcbb eceff4",
        "Dracula": "21222c ff5555 50fa7b f1fa8c bd93f9 ff79c6 8be9fd f8f8f2 6272a4 ff6e6e 69ff94 ffffA5 d6acff ff92df a4ffff ffffff",
        "Solarized Light": "073642 dc322f 859900 b58900 268bd2 d33682 2aa198 eee8d5 002b36 cb4b16 586e75 657b83 839496 6c71c4 93a1a1 fdf6e3",
        "Solarized Dark": "073642 dc322f 859900 b58900 268bd2 d33682 2aa198 eee8d5 002b36 cb4b16 586e75 657b83 839496 6c71c4 93a1a1 fdf6e3",
        "Gruvbox": "282828 cc241d 98971a d79921 458588 b16286 689d6a a89984 928374 fb4934 b8bb26 fabd2f 83a598 d3869b 8ec07c ebdbb2",
        "Catppuccin": "45475a f38ba8 a6e3a1 f9e2af 89b4fa f5c2e7 94e2d5 bac2de 585b70 f38ba8 a6e3a1 f9e2af 89b4fa f5c2e7 94e2d5 a6adc8",
        "Tokyo Night": "15161e f7768e 9ece6a e0af68 7aa2f7 bb9af7 7dcfff a9b1d6 414868 f7768e 9ece6a e0af68 7aa2f7 bb9af7 7dcfff c0caf5",
        "High Contrast": "000000 ff6666 66ff66 ffff00 66bbff ff88ff 00ffff ffffff 888888 ff8888 88ff88 ffff88 88ccff ffaaff 88ffff ffffff",
    ]

    /// The native theme's name. Its colours are macOS's own (they follow light and dark, Increase Contrast and the
    /// user's accent colour), so the app resolves them at drawing time; `system(dark:)` is their portable stand-in.
    public static let systemName = "macOS"

    /// The native theme's colours on a stock Mac (blue accent), in light or dark.
    public static func system(dark: Bool) -> Self {
        var theme =
            dark
            ? Self(name: systemName, isDark: true, background: "323232", view: "1e1e1e", text: "dfdfdf", accent: "0a84ff", secondary: "9a9a9a")
            : Self(name: systemName, isDark: false, background: "ececec", view: "ffffff", text: "1d1d1f", accent: "007aff", secondary: "808080")
        theme[.alternateRow] = dark ? ThemeColor(42, 42, 42) : ThemeColor(244, 245, 245)
        theme[.selection] = dark ? ThemeColor(0, 89, 209) : ThemeColor(0, 100, 225)
        return theme
    }

    public static let builtIns: [Self] = [
        Self(name: "Breeze Light", isDark: false, background: "eef0f5", view: "fcfcfe", text: "222634", accent: "2d76c4", secondary: "626980"),
        Self(name: "Breeze Dark", isDark: true, background: "1d212f", view: "181c27", text: "d6dbf1", accent: "4489ce", secondary: "b4bcda"),
        Self(name: "Nord", isDark: true, background: "2e3440", view: "242933", text: "eceff4", accent: "88c0d0", secondary: "d8dee9"),
        Self(name: "Dracula", isDark: true, background: "282a36", view: "21222c", text: "f8f8f2", accent: "bd93f9", secondary: "a5a8c2"),
        Self(name: "Solarized Light", isDark: false, background: "eee8d5", view: "fdf6e3", text: "657b83", accent: "268bd2", secondary: "839496"),
        Self(name: "Solarized Dark", isDark: true, background: "073642", view: "002b36", text: "93a1a1", accent: "2aa198", secondary: "839496"),
        Self(name: "Gruvbox", isDark: true, background: "282828", view: "1d2021", text: "ebdbb2", accent: "fabd2f", secondary: "a89984"),
        Self(name: "Catppuccin", isDark: true, background: "1e1e2e", view: "181825", text: "cdd6f4", accent: "cba6f7", secondary: "a6adc8"),
        Self(name: "Tokyo Night", isDark: true, background: "1a1b26", view: "16161e", text: "c0caf5", accent: "7aa2f7", secondary: "a9b1d6"),
        Self(name: "High Contrast", isDark: true, background: "000000", view: "000000", text: "ffffff", accent: "ffff00", secondary: "eeeeee"),
    ]
}
