import AppKit
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

/// Porpoise's two looks, following macOS's Light/Dark setting (or the one chosen in Settings): the Desert-Dark color
/// scheme (L4ki/Desert-Plasma-Themes, DesertDarkColor.colors) and a light scheme made to match it, as KDE's palette
/// groups. Every color is dynamic: drawn, it takes the value for the appearance it's drawn in.
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

    // [Colors:Window]
    static let windowBackground = color(dark: NSColor(rgb: 29, 33, 47), light: NSColor(rgb: 238, 240, 245))
    static let windowText = color(dark: NSColor(rgb: 214, 219, 241), light: NSColor(rgb: 34, 38, 52))
    static let windowTextInactive = color(dark: NSColor(rgb: 180, 188, 218), light: NSColor(rgb: 98, 105, 128))
    static let linkText = color(dark: NSColor(rgb: 65, 129, 194), light: NSColor(rgb: 36, 112, 186))
    static let activeText = color(dark: NSColor(rgb: 68, 137, 206), light: NSColor(rgb: 45, 118, 196))
    static let negativeText = color(dark: NSColor(rgb: 191, 97, 106), light: NSColor(rgb: 192, 57, 68))
    static let neutralText = color(dark: NSColor(rgb: 58, 129, 179), light: NSColor(rgb: 36, 106, 160))
    static let positiveText = color(dark: NSColor(rgb: 0, 106, 128), light: NSColor(rgb: 0, 122, 96))
    // [Colors:View]
    static let viewBackground = color(dark: NSColor(rgb: 24, 28, 39), light: NSColor(rgb: 252, 252, 254))
    static let viewAlternate = color(dark: NSColor(rgb: 29, 33, 47), light: NSColor(rgb: 244, 245, 249))
    static let viewText = color(dark: NSColor(rgb: 214, 219, 241), light: NSColor(rgb: 34, 38, 52))
    static let viewTextInactive = color(dark: NSColor(rgb: 180, 188, 218), light: NSColor(rgb: 98, 105, 128))
    // [Colors:Selection]
    static let selection = color(dark: NSColor(rgb: 71, 99, 130), light: NSColor(rgb: 66, 132, 210))
    static let selectionAlternate = color(dark: NSColor(rgb: 29, 153, 243), light: NSColor(rgb: 29, 133, 223))
    static let selectionText = color(dark: NSColor(rgb: 214, 219, 241), light: NSColor(rgb: 26, 30, 44))
    // Decorations
    static let focus = color(dark: NSColor(rgb: 74, 103, 136), light: NSColor(rgb: 66, 132, 210))
    /// Highlights and "done" marks in Porpoise's own windows (setup, settings).
    static let accent = activeText
    static let success = NSColor.systemGreen

    /// Breeze frame/separator color: text blended into the background at 20% (Breeze's "frameOutlineColor").
    static let frame = derived { windowText.mixed(with: windowBackground, 0.80) }
    static let separator = derived { windowText.mixed(with: windowBackground, 0.85) }
    /// The thin line under the toolbar and above the status bar, and the split view's divider.
    static let hairline = color(dark: NSColor.black.withAlphaComponent(0.30), light: NSColor.black.withAlphaComponent(0.10))
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
    static var increasedContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static let itemHoverFill = derived { windowText.withAlphaComponent(0.06) }
    static let itemHoverOutline = NSColor.clear
    /// Places panel current entry: Selection at ~23% over the window color, no outline (measured).
    static let placesSelectedFill = derived { selection.withAlphaComponent(0.23) }
    /// Split view: inactive view background is the View color with alpha 150/255 (over the window color).
    static let inactiveViewBackgroundOpaque = derived { windowBackground.mixed(with: viewBackground, 150.0 / 255.0) }

    // MARK: Light and dark

    /// The look chosen in Settings: macOS's (nil), or always light or dark.
    static var appearance: NSAppearance? {
        switch Settings.shared.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Whether the app is in its dark look now.
    static var isDark: Bool { NSApp.effectiveAppearance.isDark }

    private static var observers: [(owner: () -> AnyObject?, apply: () -> Void)] = []

    /// Runs `apply` now and whenever the look changes, with colors resolving for it: for colors handed to layers
    /// (`cgColor`), which don't follow by themselves. Kept for as long as `owner` lives.
    static func whenChanged(_ owner: AnyObject, _ apply: @escaping () -> Void) {
        let ref = { [weak owner] in owner }
        observers.append((ref, apply))
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance(apply)
    }

    /// The look changed (macOS's setting, or the one in Settings): layers take their new colors.
    static func lookChanged() {
        observers.removeAll { $0.owner() == nil }
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            for o in observers { o.apply() }
        }
    }

    // Breeze metrics
    static let frameRadius: CGFloat = 5
    static let itemRadius: CGFloat = 4.5
    static let toolbarHeight: CGFloat = 52

    // Fonts: the Mac system font (agreed), sized like KDE's 10pt Noto Sans at 96 dpi (≈13 px).
    static let fontSize: CGFloat = 13
    static var font: NSFont { .systemFont(ofSize: fontSize) }
    static var boldFont: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }
    static var smallFont: NSFont { .systemFont(ofSize: 11) }

    /// Terminal panel font: Hack (KDE's default monospace font), preferring its Nerd Font build for prompt symbols.
    static func terminalFont(size: CGFloat = 13) -> NSFont {
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
    static func iconStylesheet(selected: Bool = false, dark: Bool) -> String {
        var sheet = ""
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { sheet = stylesheet(selected: selected) }
        return sheet
    }

    private static func stylesheet(selected: Bool) -> String {
        let text = selected ? selectionText : windowText
        return """
            .ColorScheme-Text { color:\(text.hexString); }
            .ColorScheme-Background { color:\(windowBackground.hexString); }
            .ColorScheme-Highlight { color:\(selection.hexString); }
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
