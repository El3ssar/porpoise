import AppKit
import PorpoiseServices

extension NSColor {
    convenience init(rgb r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) {
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
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

/// The Desert-Dark color scheme (L4ki/Desert-Plasma-Themes, DesertDarkColor.colors), as KDE's palette groups.
enum Theme {
    // [Colors:Window]
    static let windowBackground = NSColor(rgb: 29, 33, 47)
    static let windowText = NSColor(rgb: 214, 219, 241)
    static let windowTextInactive = NSColor(rgb: 180, 188, 218)
    static let linkText = NSColor(rgb: 65, 129, 194)
    static let activeText = NSColor(rgb: 68, 137, 206)
    static let negativeText = NSColor(rgb: 191, 97, 106)
    static let neutralText = NSColor(rgb: 58, 129, 179)
    static let positiveText = NSColor(rgb: 0, 106, 128)
    // [Colors:View]
    static let viewBackground = NSColor(rgb: 24, 28, 39)
    static let viewAlternate = NSColor(rgb: 29, 33, 47)
    static let viewText = NSColor(rgb: 214, 219, 241)
    static let viewTextInactive = NSColor(rgb: 180, 188, 218)
    // [Colors:Selection]
    static let selection = NSColor(rgb: 71, 99, 130)
    static let selectionAlternate = NSColor(rgb: 29, 153, 243)
    static let selectionText = NSColor(rgb: 214, 219, 241)
    // Decorations
    static let focus = NSColor(rgb: 74, 103, 136)

    /// Breeze frame/separator color: text blended into the background at 20% (Breeze's "frameOutlineColor").
    static let frame = windowText.mixed(with: windowBackground, 0.80)
    static let separator = windowText.mixed(with: windowBackground, 0.85)
    static let buttonHoverBackground = windowText.withAlphaComponent(0.10)
    static let buttonPressedBackground = windowText.withAlphaComponent(0.16)
    /// Field (line edit) background: View background.
    static let fieldBackground = viewBackground

    // Item highlight, measured from Dolphin 25.12 + Breeze 6 with Desert-Dark (reference VM):
    // selected = Selection at 32% with a 53% outline; hover = text color at 6%, no outline.
    // Increase Contrast (Accessibility › Display) makes the selection solid and its outline opaque.
    static var itemSelectedFill: NSColor { selection.withAlphaComponent(increasedContrast ? 0.75 : 0.32) }
    static var itemSelectedHoverFill: NSColor { selection.withAlphaComponent(increasedContrast ? 0.85 : 0.45) }
    static var itemSelectedOutline: NSColor { increasedContrast ? windowText : selection.withAlphaComponent(0.55) }
    static var increasedContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static let itemHoverFill = windowText.withAlphaComponent(0.06)
    static let itemHoverOutline = NSColor.clear
    /// Places panel current entry: Selection at ~23% over the window color, no outline (measured).
    static let placesSelectedFill = selection.withAlphaComponent(0.23)
    /// Split view: inactive view background is the View color with alpha 150/255 (over the window color).
    static let inactiveViewBackgroundOpaque = windowBackground.mixed(with: viewBackground, 150.0 / 255.0)

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
        let font = families.lazy.compactMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }.first
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
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("fonts"),
                          URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/fonts")]
        guard let dir = candidates.compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    /// KIconLoader's color-scheme stylesheet, injected into SVG icons (normal state).
    static func iconStylesheet(selected: Bool = false) -> String {
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
