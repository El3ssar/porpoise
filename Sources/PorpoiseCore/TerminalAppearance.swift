import Foundation

public struct TerminalPalette: Codable, Equatable, Sendable {
    public var name: String
    public var background: ThemeColor
    public var foreground: ThemeColor
    public var colors: [ThemeColor]
    public init(name: String, background: ThemeColor, foreground: ThemeColor, colors: [ThemeColor]) {
        self.name = name; self.background = background; self.foreground = foreground; self.colors = colors
    }
    public static func iTerm(_ data: Data, name: String = "Imported iTerm scheme") throws -> Self {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppearanceError.invalidTerminalScheme
        }
        func color(_ key: String) throws -> ThemeColor {
            guard let c = plist[key] as? [String: Any] else { throw AppearanceError.invalidTerminalScheme }
            let components = ["Red Component", "Green Component", "Blue Component"].compactMap { c[$0] as? Double }
            guard components.count == 3, components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw AppearanceError.invalidTerminalScheme
            }
            return ThemeColor(Int((components[0] * 255).rounded()), Int((components[1] * 255).rounded()), Int((components[2] * 255).rounded()))
        }
        return try Self(
            name: name, background: color("Background Color"), foreground: color("Foreground Color"),
            colors: (0..<16).map { try color("Ansi \($0) Color") })
    }
    public static func konsole(_ text: String, name: String) -> Self {
        let s = KonsoleScheme.parse(text)
        return Self(
            name: name, background: s.background.map { ThemeColor($0.0, $0.1, $0.2) } ?? ThemeColor(29, 33, 47),
            foreground: s.foreground.map { ThemeColor($0.0, $0.1, $0.2) } ?? ThemeColor(214, 219, 241),
            colors: s.palette.map { ThemeColor($0.0, $0.1, $0.2) })
    }
    public static var builtIns: [Self] {
        AppearanceTheme.builtIns.map { Self(name: $0.name, background: $0[.windowBackground], foreground: $0[.text], colors: $0.terminalPalette) }
    }
}

public enum ShellChoice: String, Codable, CaseIterable, Sendable {
    case login, zsh, bash, fish, nu, custom
    public var title: String { self == .login ? "Login shell" : self == .custom ? "Custom" : rawValue }
    public func executable(
        custom: String, environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        if self == .custom { return custom }
        if self == .login { return environment["SHELL"] ?? "/bin/zsh" }
        let paths = (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin").split(separator: ":").map(String.init)
        return (["/bin", "/opt/homebrew/bin", "/usr/local/bin"] + paths).map { $0 + "/" + rawValue }.first(where: isExecutable) ?? "/bin/" + rawValue
    }
    public var arguments: [String] { self == .nu ? ["--login"] : self == .custom ? [] : ["-l"] }
}

public enum ExternalTerminalChoice: String, Codable, CaseIterable, Sendable {
    case automatic, terminal, iTerm, kitty, wezTerm, ghostty, alacritty, warp, custom
    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .terminal: return "Terminal"
        case .iTerm: return "iTerm2"
        case .kitty: return "kitty"
        case .wezTerm: return "WezTerm"
        case .ghostty: return "Ghostty"
        case .alacritty: return "Alacritty"
        case .warp: return "Warp"
        case .custom: return "Custom command"
        }
    }
    public var bundleID: String? {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iTerm: return "com.googlecode.iterm2"
        case .kitty: return "net.kovidgoyal.kitty"
        case .wezTerm: return "com.github.wez.wezterm"
        case .ghostty: return "com.mitchellh.ghostty"
        case .alacritty: return "org.alacritty"
        case .warp: return "dev.warp.Warp-Stable"
        default: return nil
        }
    }
    public static func installed(resolve: (String) -> Bool) -> [Self] { allCases.filter { $0.bundleID.map(resolve) ?? false } }
}

public enum TerminalCommandTemplate {
    /// The placeholder includes shell quoting. Templates must use bare {dir}, without their own quotes.
    public static func expand(_ template: String, directory: String) throws -> String {
        guard template.contains("{dir}") else { throw AppearanceError.invalidTemplate }
        // Quotes around an already-quoted replacement would re-enable expansion of path contents.
        let characters = Array(template), placeholder = Array("{dir}")
        var index = 0, replacements = 0
        var quoteMode: Character?
        while index < characters.count {
            if characters[index...].starts(with: placeholder) {
                guard quoteMode == nil, index == 0 || ![Character("$"), Character("\\")].contains(characters[index - 1]) else {
                    throw AppearanceError.invalidTemplate
                }
                replacements += 1; index += 5; continue
            }
            let c = characters[index]
            if c == "\\", quoteMode != "'" { index += 2; continue }
            if c == "'" || c == "\"" {
                if quoteMode == c { quoteMode = nil } else if quoteMode == nil { quoteMode = c }
            }
            index += 1
        }
        guard quoteMode == nil, replacements == template.components(separatedBy: "{dir}").count - 1 else { throw AppearanceError.invalidTemplate }
        return template.replacingOccurrences(of: "{dir}", with: quote(directory))
    }
    /// By code point (`RemoteParsing.quote`): a Character-based replace misses a quote followed by a combining mark.
    public static func quote(_ value: String) -> String { RemoteParsing.quote(value) }
}

public enum ViewDensity: String, Codable, CaseIterable, Sendable {
    case compact, normal, comfortable
    public var padding: Double { self == .compact ? 1 : self == .normal ? 2 : 6 }
}

/// Complete portable appearance settings. This schema is versioned independently of UserDefaults keys.
public struct AppearancePreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var themeName = "Follow system"
    public var customTheme: AppearanceTheme?
    public var lightThemeName = "Breeze Light"
    public var darkThemeName = "Breeze Dark"
    public var iconTheme = "Tela-circle"
    public var folderVariant = "default"
    public var uiFontName = ""
    public var uiFontSize = 13.0
    public var fileFontName = ""
    public var fileFontSize = 13.0
    public var density = ViewDensity.normal
    public var iconsSize = 64
    public var compactSize = 32
    public var detailsSize = 32
    public var shell = ShellChoice.login
    public var customShell = "/bin/zsh"
    public var shellArguments: [String] = []
    public var terminalFontName = ""
    public var terminalFontSize = 13.0
    public var terminalScheme = "Follow theme"
    public var customTerminalPalette: TerminalPalette?
    public var cursor = "block"
    public var scrollback = 10000
    public var externalTerminal = ExternalTerminalChoice.automatic
    public var externalCommand = "open -a Terminal {dir}"
    public var appearance = "system"
    public init() {}
    /// Fields missing from older files (or saved settings) keep their defaults: adding a field must not make every
    /// stored appearance unreadable (the synthesized decoder requires every key).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(type(of: version).self, forKey: .version) ?? version
        themeName = try c.decodeIfPresent(type(of: themeName).self, forKey: .themeName) ?? themeName
        customTheme = try c.decodeIfPresent(type(of: customTheme).self, forKey: .customTheme) ?? nil
        lightThemeName = try c.decodeIfPresent(type(of: lightThemeName).self, forKey: .lightThemeName) ?? lightThemeName
        darkThemeName = try c.decodeIfPresent(type(of: darkThemeName).self, forKey: .darkThemeName) ?? darkThemeName
        iconTheme = try c.decodeIfPresent(type(of: iconTheme).self, forKey: .iconTheme) ?? iconTheme
        folderVariant = try c.decodeIfPresent(type(of: folderVariant).self, forKey: .folderVariant) ?? folderVariant
        uiFontName = try c.decodeIfPresent(type(of: uiFontName).self, forKey: .uiFontName) ?? uiFontName
        uiFontSize = try c.decodeIfPresent(type(of: uiFontSize).self, forKey: .uiFontSize) ?? uiFontSize
        fileFontName = try c.decodeIfPresent(type(of: fileFontName).self, forKey: .fileFontName) ?? fileFontName
        fileFontSize = try c.decodeIfPresent(type(of: fileFontSize).self, forKey: .fileFontSize) ?? fileFontSize
        density = try c.decodeIfPresent(type(of: density).self, forKey: .density) ?? density
        iconsSize = try c.decodeIfPresent(type(of: iconsSize).self, forKey: .iconsSize) ?? iconsSize
        compactSize = try c.decodeIfPresent(type(of: compactSize).self, forKey: .compactSize) ?? compactSize
        detailsSize = try c.decodeIfPresent(type(of: detailsSize).self, forKey: .detailsSize) ?? detailsSize
        shell = try c.decodeIfPresent(type(of: shell).self, forKey: .shell) ?? shell
        customShell = try c.decodeIfPresent(type(of: customShell).self, forKey: .customShell) ?? customShell
        shellArguments = try c.decodeIfPresent(type(of: shellArguments).self, forKey: .shellArguments) ?? shellArguments
        terminalFontName = try c.decodeIfPresent(type(of: terminalFontName).self, forKey: .terminalFontName) ?? terminalFontName
        terminalFontSize = try c.decodeIfPresent(type(of: terminalFontSize).self, forKey: .terminalFontSize) ?? terminalFontSize
        terminalScheme = try c.decodeIfPresent(type(of: terminalScheme).self, forKey: .terminalScheme) ?? terminalScheme
        customTerminalPalette = try c.decodeIfPresent(type(of: customTerminalPalette).self, forKey: .customTerminalPalette) ?? nil
        cursor = try c.decodeIfPresent(type(of: cursor).self, forKey: .cursor) ?? cursor
        scrollback = try c.decodeIfPresent(type(of: scrollback).self, forKey: .scrollback) ?? scrollback
        externalTerminal = try c.decodeIfPresent(type(of: externalTerminal).self, forKey: .externalTerminal) ?? externalTerminal
        externalCommand = try c.decodeIfPresent(type(of: externalCommand).self, forKey: .externalCommand) ?? externalCommand
        appearance = try c.decodeIfPresent(type(of: appearance).self, forKey: .appearance) ?? appearance
    }
    public func validate() throws {
        guard version == 1, [uiFontSize, fileFontSize, terminalFontSize].allSatisfy({ $0.isFinite && (6...72).contains($0) }),
            [iconsSize, compactSize, detailsSize].allSatisfy({ (8...512).contains($0) }), (0...1_000_000).contains(scrollback),
            ["block", "bar", "underline"].contains(cursor), ["system", "light", "dark"].contains(appearance),
            // Becomes part of an icon's file name: a plain name only.
            !folderVariant.isEmpty, folderVariant.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        else { throw AppearanceError.invalidTheme }
        try customTheme?.validate()
        if let p = customTerminalPalette, p.colors.count != 16 { throw AppearanceError.invalidTerminalScheme }
        if externalTerminal == .custom { _ = try TerminalCommandTemplate.expand(externalCommand, directory: "/") }
    }
    public func theme(dark: Bool) -> AppearanceTheme {
        if themeName == "Custom", let customTheme { return customTheme }
        let name = themeName == "Follow system" ? (dark ? darkThemeName : lightThemeName) : themeName
        return AppearanceTheme.builtIns.first { $0.name == name } ?? AppearanceTheme.builtIns[dark ? 1 : 0]
    }
}
