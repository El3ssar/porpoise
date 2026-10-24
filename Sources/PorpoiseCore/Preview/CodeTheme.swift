import Foundation

/// Code has its own appearance: GitHub Dark is the default in both application looks.
public enum CodeTheme: String, Codable, CaseIterable, Sendable {
    case githubDark, githubLight, followAppearance

    public var title: String {
        switch self {
        case .githubDark: return "GitHub Dark"
        case .githubLight: return "GitHub Light"
        case .followAppearance: return "Follow appearance"
        }
    }

    public func palette(darkAppearance: Bool) -> CodePalette {
        self == .githubLight || self == .followAppearance && !darkAppearance ? .light : .dark
    }
}

/// Primer default syntax colors, independent of the file manager's theme and terminal palette.
/// Source: github.com/primer/github-vscode-theme, src/theme.js and src/colors.js.
public struct CodePalette: Equatable, Sendable {
    public let background: ThemeColor
    public let text: ThemeColor
    public let keyword: ThemeColor
    public let string: ThemeColor
    public let comment: ThemeColor
    public let function: ThemeColor
    public let constant: ThemeColor
    public let type: ThemeColor
    public let tag: ThemeColor
    public let deleted: ThemeColor
    public let inserted: ThemeColor
    public let isDark: Bool

    public func color(for kind: SyntaxToken.Kind) -> ThemeColor {
        switch kind {
        case .keyword: return keyword
        case .type, .attribute: return type
        case .string: return string
        case .comment: return comment
        case .function: return function
        case .number, .constant, .key, .heading: return constant
        case .tag: return tag
        case .deleted: return deleted
        case .inserted: return inserted
        }
    }

    public static let dark = CodePalette(
        background: ThemeColor(13, 17, 23), text: ThemeColor(230, 237, 243), keyword: ThemeColor(255, 123, 114),
        string: ThemeColor(165, 214, 255), comment: ThemeColor(139, 148, 158), function: ThemeColor(210, 168, 255),
        constant: ThemeColor(121, 192, 255), type: ThemeColor(255, 166, 87), tag: ThemeColor(126, 231, 135),
        deleted: ThemeColor(255, 220, 215), inserted: ThemeColor(175, 245, 180), isDark: true)

    public static let light = CodePalette(
        background: ThemeColor(255, 255, 255), text: ThemeColor(31, 35, 40), keyword: ThemeColor(207, 34, 46),
        string: ThemeColor(10, 48, 105), comment: ThemeColor(110, 119, 129), function: ThemeColor(130, 80, 223),
        constant: ThemeColor(5, 80, 174), type: ThemeColor(149, 56, 0), tag: ThemeColor(17, 99, 41),
        deleted: ThemeColor(130, 7, 30), inserted: ThemeColor(17, 99, 41), isDark: false)
}
