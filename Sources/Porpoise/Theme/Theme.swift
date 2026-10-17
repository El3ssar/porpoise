import AppKit
import PorpoiseCore
import PorpoiseServices

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    convenience init(rgb r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) {
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
            Int(round(c.blueComponent * 255)))
    }

    /// QColor::lighter(factor) equivalent (factor 110 = 10% lighter).
    func lighter(_ factor: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: s, brightness: min(1, b * factor / 100), alpha: a)
    }

    func mixed(with other: NSColor, _ t: CGFloat) -> NSColor {
        blended(withFraction: t, of: other) ?? self
    }
}

/// The app's semantic palette. Dynamic colours resolve the selected portable theme at drawing time;
/// layer colours are refreshed by `lookChanged` when either the theme or system appearance changes.
enum Theme {
    /// A color with a value for each look.
    static func color(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }

    /// A color worked out from others (blends, alphas): computed in the appearance it's drawn in.
    static func derived(_ make: @escaping () -> NSColor) -> NSColor {
        NSColor(name: nil) { a in
            var c = NSColor.clear
            a.performAsCurrentDrawingAppearance { c = make().usingColorSpace(.sRGB) ?? make() }
            return c
        }
    }

    static func paletteColor(_ role: ThemeRole) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = Settings.shared.appearancePreferences.theme(dark: appearance.isDark)[role]
            return NSColor(rgb: c.red, c.green, c.blue)
        }
    }

    static let windowBackground = paletteColor(.windowBackground)
    static let windowText = paletteColor(.text)
    static let windowTextInactive = paletteColor(.secondaryText)
    static let activeText = paletteColor(.accent)
    static let negativeText = color(dark: NSColor(rgb: 191, 97, 106), light: NSColor(rgb: 192, 57, 68))
    static let neutralText = paletteColor(.accent)
    static let positiveText = color(dark: NSColor(rgb: 0, 160, 128), light: NSColor(rgb: 0, 122, 96))
    // Transfer semantic text colours, with contrast on both alternating row backgrounds.
    static let transferPositive = color(dark: NSColor(rgb: 43, 181, 148), light: NSColor(rgb: 0, 122, 96))
    static let transferChanged = color(dark: NSColor(rgb: 216, 166, 87), light: NSColor(rgb: 161, 92, 0))
    static let transferDanger = color(dark: NSColor(rgb: 224, 112, 122), light: NSColor(rgb: 192, 57, 68))
    static let viewBackground = paletteColor(.viewBackground)
    static let viewAlternate = paletteColor(.alternateRow)
    static let viewText = paletteColor(.text)
    static let viewTextInactive = paletteColor(.secondaryText)
    static let selection = paletteColor(.selection)
    static let selectionAlternate = paletteColor(.accent)
    static let selectionText = paletteColor(.selectionText)
    static let focus = paletteColor(.accent)
    static let accent = paletteColor(.accent)
    static let success = positiveText
    static let panelBackground = paletteColor(.panel)
    static let sidebarBackground = paletteColor(.sidebar)
    static let folderTint = paletteColor(.folderTint)

    /// Breeze frame/separator color: text blended into the background at 20% (Breeze's "frameOutlineColor").
    static let frame = derived { windowText.mixed(with: windowBackground, 0.80) }
    static let separator = derived { windowText.mixed(with: windowBackground, 0.85) }
    /// The thin line under the toolbar and above the status bar, and the split view's divider.
    static let hairline = color(dark: NSColor.black.withAlphaComponent(0.30), light: NSColor.black.withAlphaComponent(0.10))
    /// A disabled label: the text color, faded.
    static let disabledText = derived { windowText.withAlphaComponent(0.4) }
    static let buttonHoverBackground = derived { windowText.withAlphaComponent(0.10) }
    static let buttonPressedBackground = derived { windowText.withAlphaComponent(0.16) }
    /// Field (line edit) background: View background.
    static let fieldBackground = viewBackground

    // Item highlight, measured from Dolphin 25.12 + Breeze 6 with Desert-Dark (reference VM):
    // selected = Selection at 32% with a 53% outline; hover = text color at 6%, no outline.
    // Increase Contrast (Accessibility › Display) makes the selection solid and its outline opaque.
    static var itemSelectedFill: NSColor { selection.withAlphaComponent(increasedContrast ? 0.75 : 0.32) }
    static var itemSelectedHoverFill: NSColor { selection.withAlphaComponent(increasedContrast ? 0.85 : 0.45) }
    static var itemSelectedOutline: NSColor { increasedContrast ? windowText : selection.withAlphaComponent(0.55) }
    static var increasedContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || Settings.shared.appearancePreferences.theme(dark: isDark).name == "High Contrast"
    }
    static let itemHoverFill = derived { paletteColor(.hover).withAlphaComponent(0.06) }
    static let itemHoverOutline = NSColor.clear
    /// Places panel current entry: Selection at ~23% over the window color, no outline (measured).
    static let placesSelectedFill = derived { selection.withAlphaComponent(0.23) }
    /// Split view: inactive view background is the View color with alpha 150/255 (over the window color).
    static let inactiveViewBackgroundOpaque = derived { windowBackground.mixed(with: viewBackground, 150.0 / 255.0) }

    // MARK: Light and dark

    /// The look chosen in Settings: macOS's (nil), or always light or dark.
    static var appearance: NSAppearance? {
        let preferences = Settings.shared.appearancePreferences
        if preferences.themeName != "Follow system" {
            return NSAppearance(named: preferences.theme(dark: isDark).isDark ? .darkAqua : .aqua)
        }
        switch Settings.shared.appearance {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Whether the app is in its dark look now.
    static var isDark: Bool { NSApp.effectiveAppearance.isDark }

    private static var observers: [(owner: () -> AnyObject?, apply: () -> Void)] = []

    /// Runs `apply` now and whenever the look changes, with colors resolving for it: for colors handed to layers
    /// (`cgColor`), which don't follow by themselves. Kept for as long as `owner` lives.
    static func whenChanged(_ owner: AnyObject, _ apply: @escaping () -> Void) {
        let ref = { [weak owner] in owner }
        // Pruned here too: owners that come and go (every conflict dialog) would pile up until the next change.
        observers.removeAll { $0.owner() == nil }
        observers.append((ref, apply))
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance(apply)
    }

    /// The look changed (macOS's setting, or the one in Settings): layers take their new colors.
    static func lookChanged() {
        observers.removeAll { $0.owner() == nil }
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            for o in observers { o.apply() }
            for window in NSApp.windows {
                window.backgroundColor = Theme.windowBackground.usingColorSpace(.sRGB) ?? Theme.windowBackground
                window.contentView?.redrawAll()
            }
            redressWindows()
        }
    }

    // Breeze metrics
    static let frameRadius: CGFloat = 5
    static let itemRadius: CGFloat = 4.5
    static let toolbarHeight: CGFloat = 52

    // Fonts: the Mac system font (agreed), sized like KDE's 10pt Noto Sans at 96 dpi (≈13 px).
    static var fontSize: CGFloat { CGFloat(Settings.shared.appearancePreferences.uiFontSize) }
    static var font: NSFont { NSFont(name: Settings.shared.appearancePreferences.uiFontName, size: fontSize) ?? .systemFont(ofSize: fontSize) }
    static var boldFont: NSFont { NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    static var smallFont: NSFont { NSFontManager.shared.convert(font, toSize: max(8, fontSize - 2)) }

    /// Terminal panel font: Hack (KDE's default monospace font), preferring its Nerd Font build for prompt symbols.
    static func terminalFont() -> NSFont {
        let preferences = Settings.shared.appearancePreferences
        let size = CGFloat(preferences.terminalFontSize)
        if let custom = NSFont(name: preferences.terminalFontName, size: size) { return custom }
        let families = ["Hack Nerd Font Mono", "Hack Nerd Font", "Hack", "JetBrainsMono Nerd Font Mono", "MesloLGS NF", "Menlo"]
        // Weight 5 is NSFontManager's "regular".
        let font =
            families.lazy.compactMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }.first
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        // Nerd Font symbols (prompt icons) fall back to the bundled Symbols Nerd Font, like kitty does.
        registerBundledFonts()
        let symbols = NSFontDescriptor(fontAttributes: [.name: "SymbolsNFM"])
        let d = font.fontDescriptor.addingAttributes([.cascadeList: [symbols]])
        return NSFont(descriptor: d, size: size) ?? font
    }

    private static var fontsRegistered = false

    /// Registers the bundled fonts (Symbols Nerd Font) for this process, once. Under `swift run` they come from
    /// the project's Resources folder.
    private static func registerBundledFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        let fm = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("fonts"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/fonts"),
        ]
        guard let dir = candidates.compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    /// KIconLoader's color-scheme stylesheet, injected into SVG icons (normal state), for the dark or light look.
    static func iconStylesheet(selected: Bool = false, dark: Bool, folder: Bool = false) -> String {
        var sheet = ""
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { sheet = stylesheet(selected: selected, folder: folder) }
        return sheet
    }

    private static func stylesheet(selected: Bool, folder: Bool) -> String {
        let text = selected ? selectionText : windowText
        return """
            .ColorScheme-Text { color:\(text.hexString); }
            .ColorScheme-Background { color:\(windowBackground.hexString); }
            .ColorScheme-Highlight { color:\((folder ? folderTint : selection).hexString); }
            .ColorScheme-HighlightedText { color:\(selectionText.hexString); }
            .ColorScheme-PositiveText { color:\(positiveText.hexString); }
            .ColorScheme-NeutralText { color:\(neutralText.hexString); }
            .ColorScheme-NegativeText { color:\(negativeText.hexString); }
            .ColorScheme-ActiveText { color:\(activeText.hexString); }
            .ColorScheme-Complement { color:\(windowBackground.hexString); }
            .ColorScheme-Contrast { color:\(windowText.hexString); }
            .ColorScheme-Accent { color:\(selection.hexString); }
            """
    }
}

extension NSView {
    /// Marks this view and everything inside it for redrawing.
    func redrawAll() {
        needsDisplay = true
        subviews.forEach { $0.redrawAll() }
    }
}
