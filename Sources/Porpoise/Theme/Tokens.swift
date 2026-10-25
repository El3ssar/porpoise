import AppKit
import PorpoiseCore
import PorpoiseServices

/// The design tokens of the native "macOS" theme, the default: system colours that follow light and dark, Increase
/// Contrast and the user's accent colour, and the type, corner and spacing scales new UI is built from.
enum Tokens {
    /// Whether the chosen theme is the native one: its colours come from macOS, not from a palette.
    static var isNative: Bool { Settings.shared.appearancePreferences.usesSystemColors }

    /// An accent colour that replaces the user's (tests set it, so a machine's own setting can't change what they see).
    nonisolated(unsafe) static var accentOverride: NSColor?

    /// The user's accent colour (System Settings › Appearance).
    static var accent: NSColor { accentOverride ?? .controlAccentColor }

    /// The selection in the focused view: macOS's, which follows the accent colour.
    static var selection: NSColor { accentOverride ?? .selectedContentBackgroundColor }

    /// The selection in a view that isn't focused, or a window that isn't key: macOS's grey. In dark it is only about
    /// 1.5:1 against the alternate rows, so it is lightened until it stands out from both rows by 1.8:1.
    static let unemphasizedSelection = NSColor(name: nil) { appearance in
        var c = NSColor.unemphasizedSelectedContentBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            let system = opaque(.unemphasizedSelectedContentBackgroundColor)
            let rows = [opaque(.controlBackgroundColor), opaque(color(.alternateRow))]
            c = appearance.isDark ? distinct(system, from: rows, toward: .white, ratio: 1.8) : system
        }
        return c
    }

    /// Behind a selected item's icon in Icons view (Finder's neutral backing): the accent goes behind the name only.
    static let iconSelectionBacking = NSColor.quaternaryLabelColor

    /// The system colour for each theme role.
    static func color(_ role: ThemeRole) -> NSColor {
        switch role {
        case .windowBackground, .panel, .sidebar: return .windowBackgroundColor
        case .viewBackground: return .controlBackgroundColor
        case .alternateRow: return NSColor.alternatingContentBackgroundColors[1]
        case .selection: return selection
        case .selectionText: return .alternateSelectedControlTextColor
        case .text, .hover: return .labelColor
        case .secondaryText: return .secondaryLabelColor
        case .accent, .folderTint: return accent
        }
    }

    /// `role` as an opaque sRGB colour in `appearance`. A translucent one (the dark alternate row is white at 5%) is
    /// laid over the view background, as it's drawn. The selection stands out from the rows by at least 3:1 (WCAG
    /// 1.4.11): macOS's dark selection is only about 2.6:1 against its rows, so it is lightened until it is.
    static func resolved(_ role: ThemeRole, in appearance: NSAppearance) -> NSColor {
        var c = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            c = opaque(color(role))
            if role == .selection {
                c = distinct(c, from: [opaque(.controlBackgroundColor), opaque(color(.alternateRow))], toward: appearance.isDark ? .white : .black)
            }
        }
        return c
    }

    /// `color` in sRGB, laid over the view background if translucent (in the current drawing appearance).
    private static func opaque(_ color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? .black
        guard c.alphaComponent < 1, let base = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) else { return c }
        return base.blended(withFraction: c.alphaComponent, of: c.withAlphaComponent(1)) ?? c
    }

    /// `color` mixed toward `target` in small steps until its contrast with each of `backgrounds` is at least `ratio`.
    static func distinct(_ color: NSColor, from backgrounds: [NSColor], toward target: NSColor, ratio: CGFloat = 3) -> NSColor {
        var c = color
        for step in 1...20 where backgrounds.contains(where: { contrast(c, $0) < ratio }) {
            c = color.blended(withFraction: CGFloat(step) * 0.05, of: target) ?? c
        }
        return c
    }

    /// WCAG 2 contrast ratio of two opaque sRGB colours (1 to 21).
    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG 2 relative luminance of an sRGB colour.
    static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    /// The native theme as a portable palette, in light or dark: what the theme gallery previews, Export Theme writes
    /// and a custom theme starts from.
    static func palette(dark: Bool) -> AppearanceTheme {
        var theme = AppearanceTheme.system(dark: dark)
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return theme }
        for role in ThemeRole.allCases { theme[role] = themeColor(resolved(role, in: appearance)) }
        return theme
    }

    static func themeColor(_ c: NSColor) -> ThemeColor {
        ThemeColor(Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    // Status colours.
    static let success = NSColor.systemGreen
    static let warning = NSColor.systemOrange
    static let danger = NSColor.systemRed

    /// The type scale (DESIGN-CONTRACT §2): each style's size at 13 pt and its weight.
    enum TextStyle: CaseIterable {
        case largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote, caption, mono

        var size: CGFloat {
            switch self {
            case .largeTitle: return FontSize.largeTitle
            case .title: return FontSize.title
            case .title2: return FontSize.title2
            case .title3: return FontSize.title3
            case .headline, .body: return FontSize.body
            case .callout, .mono: return FontSize.callout
            case .subheadline, .footnote: return FontSize.small
            case .caption: return FontSize.caption
            }
        }

        var weight: NSFont.Weight {
            switch self {
            case .largeTitle: return .bold
            case .title, .title2, .title3, .headline, .subheadline: return .semibold
            case .caption: return .medium
            case .body, .callout, .footnote, .mono: return .regular
            }
        }
    }

    /// The system font in `style` (SF Mono for `.mono`). `scaled`: sized for Settings › font size, for the main
    /// window's content (its views, panels and bars); secondary windows and dialogs keep macOS's sizes, as macOS's own
    /// do. `weight` replaces the style's; `digits` gives numbers that change in place equal widths.
    static func font(_ style: TextStyle, weight: NSFont.Weight? = nil, digits: Bool = false, scaled: Bool = false) -> NSFont {
        let size = scaled ? FontSize.scaled(style.size) : style.size
        let w = weight ?? style.weight
        if style == .mono { return .monospacedSystemFont(ofSize: size, weight: w) }
        return digits ? .monospacedDigitSystemFont(ofSize: size, weight: w) : .systemFont(ofSize: size, weight: w)
    }

    /// Type sizes for 13 pt body text (`TextStyle` is the API; these are its table), scaled with Settings › font size
    /// (`scaled`).
    enum FontSize {
        static let caption: CGFloat = 10
        static let small: CGFloat = 11
        /// macOS's callout style: secondary lines, table cells and metadata.
        static let callout: CGFloat = 12
        static let body: CGFloat = 13
        static let title3: CGFloat = 15
        static let title2: CGFloat = 17
        static let title: CGFloat = 22
        static let largeTitle: CGFloat = 26

        /// `size` scaled by the font size chosen in Settings (13 pt is 1×).
        static func scaled(_ size: CGFloat) -> CGFloat { (size * Theme.fontSize / body).rounded() }
    }

    /// Corner radii: small controls, rows, cards, sheets.
    enum Radius {
        /// Progress and capacity bars (height 6 or less).
        static let xsmall: CGFloat = 2
        /// Badges, tag chips, the rename field, focus masks of small controls.
        static let small: CGFloat = 4
        static let row: CGFloat = 6
        /// Preview surfaces, cards inside sheets, the icon backing of a selected item in Icons view.
        static let medium: CGFloat = 8
        static let card: CGFloat = 10
        static let sheet: CGFloat = 14
    }

    /// The 4-pt spacing grid (DESIGN-CONTRACT §3).
    enum Space {
        /// Hairline gaps: a badge to its text, an icon to its overlay.
        static let xxs: CGFloat = 2
        /// Inside tight controls; a label to its inline badge.
        static let xs: CGFloat = 4
        /// Related controls in a row; a label to its control; a cell's inner padding.
        static let s: CGFloat = 8
        /// Rows of a form; a heading to its group.
        static let m: CGFloat = 12
        /// A group's inner padding; between cards.
        static let l: CGFloat = 16
        /// Window and sheet content margins (HIG); between form groups.
        static let xl: CGFloat = 20
        /// Above a sheet's button row; empty-state blocks.
        static let xxl: CGFloat = 24
        /// Around hero empty states and onboarding.
        static let xxxl: CGFloat = 32
    }

    /// Named chrome metrics (DESIGN-CONTRACT §3).
    enum Metric {
        /// A form's label column at its narrowest; a page's column is as wide as its longest label.
        static let formLabelColumn: CGFloat = 120
        /// A window's or a sheet's content margins: 20 pt on every side (S2).
        static let windowInsets = NSEdgeInsets(top: Space.xl, left: Space.xl, bottom: Space.xl, right: Space.xl)
    }
}
