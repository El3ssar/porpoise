import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized) @MainActor struct NativeThemeTests {
    init() { _ = NSApplication.shared }

    /// `color` as sRGB 0–255 in light or dark.
    private func rgb(_ color: NSColor, dark: Bool) -> [Int] {
        var c = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { c = color.usingColorSpace(.sRGB) ?? color }
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    /// labelColor (translucent) laid over controlBackgroundColor, as drawn.
    private func labelOverView(_ dark: Bool) -> [Int] {
        var c = NSColor.black
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
            let view = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) ?? .black
            c = view.blended(withFraction: label.alphaComponent, of: label.withAlphaComponent(1)) ?? view
        }
        return rgb(c, dark: dark)
    }

    private func close(_ a: [Int], _ b: [Int], within tolerance: Int = 3) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= tolerance } }

    @Test(.isolatedSettings) func defaultThemeResolvesToSystemColours() {
        #expect(Tokens.isNative && Settings.shared.appearancePreferences.iconTheme == "Native macOS")
        for dark in [false, true] {
            #expect(rgb(Theme.viewBackground, dark: dark) == rgb(.controlBackgroundColor, dark: dark))
            #expect(rgb(Theme.windowBackground, dark: dark) == rgb(.windowBackgroundColor, dark: dark))
            // Translucent system text, laid over the view.
            let label = labelOverView(dark)
            #expect(close(rgb(Theme.windowText, dark: dark), label, within: 1))
            #expect(rgb(Theme.separator, dark: dark) == rgb(.separatorColor, dark: dark))
            #expect(rgb(Theme.negativeText, dark: dark) == rgb(.systemRed, dark: dark))
        }
        // Graphite, not Breeze's navy #181c27.
        #expect(close(rgb(Theme.viewBackground, dark: true), [30, 30, 30]))
        // The dark alternate row (white at 5%) as drawn over the view, opaque.
        #expect(close(rgb(Theme.viewAlternate, dark: true), [42, 42, 42], within: 4))
        // Light and dark follow the Appearance setting, as with "Follow system".
        Settings.shared.appearance = .dark
        #expect(Theme.appearance?.name == .darkAqua)
        Settings.shared.appearance = .system
        #expect(Theme.appearance == nil)
    }

    @Test(.isolatedSettings) func selectionFocusAndFoldersFollowTheAccentColour() {
        let pink = NSColor(srgbRed: 1, green: 0.2, blue: 0.6, alpha: 1)
        Tokens.accentOverride = pink
        defer { Tokens.accentOverride = nil }
        for dark in [false, true] {
            for color in [Theme.accent, Theme.focus, Theme.selection, Theme.selectionAlternate, Theme.folderTint] {
                #expect(rgb(color, dark: dark) == [255, 51, 153])
            }
            #expect(Theme.paletteColor(.folderTint, dark: dark) == ThemeColor(255, 51, 153))
            #expect(Theme.palette(dark: dark)[.selection] == ThemeColor(255, 51, 153))
        }
        // A palette theme keeps its own accent.
        Settings.shared.updateAppearance { $0.themeName = "Breeze Light" }
        #expect(rgb(Theme.accent, dark: false) == [45, 118, 196])
    }

    @Test(.isolatedSettings) func paletteThemesRenderAsBefore() {
        Settings.shared.updateAppearance {
            $0.themeName = "Follow system"; $0.iconTheme = "Tela-circle"
        }
        #expect(!Tokens.isNative)
        #expect(rgb(Theme.viewBackground, dark: true) == [24, 28, 39] && rgb(Theme.viewBackground, dark: false) == [252, 252, 254])
        #expect(Theme.palette(dark: true) == AppearanceTheme.builtIns[1])
        #expect(rgb(Theme.negativeText, dark: false) == [192, 57, 68])
        // The breeze separator: text at 15% over the window.
        #expect(
            close(
                rgb(Theme.separator, dark: false), rgb(NSColor(rgb: 34, 38, 52).mixed(with: NSColor(rgb: 238, 240, 245), 0.85), dark: false),
                within: 1))
        // A fixed palette sets its own look.
        Settings.shared.updateAppearance { $0.themeName = "Nord" }
        #expect(Theme.appearance?.name == .darkAqua)
    }

    @Test(.isolatedSettings) func materialsAreUntintedOnlyInTheNativeTheme() {
        let saved = TintedMaterialView.reducesTransparency
        defer { TintedMaterialView.reducesTransparency = saved }
        let material = TintedMaterialView(material: .sidebar, tint: Theme.sidebarBackground, alpha: 0.70)
        func tintAlpha(reducingTransparency: Bool) -> CGFloat {
            TintedMaterialView.reducesTransparency = { reducingTransparency }
            Theme.lookChanged()
            return material.tintLayer.backgroundColor?.alpha ?? -1
        }
        // Native: untinted, also with Reduce Transparency (the material turns opaque by itself).
        #expect(tintAlpha(reducingTransparency: false) == 0 && tintAlpha(reducingTransparency: true) == 0)
        // A palette: tinted at 70%, opaque with Reduce Transparency.
        Settings.shared.updateAppearance { $0.themeName = "Breeze Dark" }
        #expect(abs(tintAlpha(reducingTransparency: false) - 0.70) < 0.001)
        #expect(tintAlpha(reducingTransparency: true) == 1)
    }

    @Test(.isolatedSettings) func increaseContrastStrengthensPaletteLines() {
        Settings.shared.updateAppearance { $0.themeName = "Breeze Light" }
        let saved = Theme.systemIncreasesContrast
        defer { Theme.systemIncreasesContrast = saved }
        func measure() -> [[Int]] {
            [Theme.separator, Theme.frame, Theme.hairline, Theme.disabledText, Theme.itemHoverFill, Theme.placesSelectedFill].map { color in
                var c = color
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { c = color.usingColorSpace(.sRGB) ?? color }
                return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
            }
        }
        Theme.systemIncreasesContrast = { false }
        let normal = measure()
        Theme.systemIncreasesContrast = { true }
        let increased = measure()
        // Separator and frame: darker; hairline, disabled text, hover and the Places selection: more opaque.
        #expect(increased[0][0] < normal[0][0] && increased[1][0] < normal[1][0])
        for i in 2..<6 { #expect(increased[i][3] > normal[i][3]) }
    }

    @Test(.isolatedSettings) func selectionStandsOutFromTheRowsAtThreeToOne() {
        for dark in [false, true] {
            let selection = rgb(Theme.selection, dark: dark)
            for row in [Theme.viewBackground, Theme.viewAlternate] {
                let ratio = Tokens.contrast(color(selection), color(rgb(row, dark: dark)))
                #expect(ratio >= 3, "\(dark ? "dark" : "light") selection \(selection) only \(ratio):1")
            }
            // White text and glyphs on it.
            #expect(rgb(Theme.selectionText, dark: dark) == [255, 255, 255])
        }
        // A pale accent is darkened in light, so it still reads.
        let pale = NSColor(srgbRed: 1, green: 0.85, blue: 0.3, alpha: 1)
        let white = NSColor.white, alternate = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        let raised = Tokens.distinct(pale, from: [white, alternate], toward: .black)
        #expect(Tokens.contrast(raised, white) >= 3 && Tokens.contrast(raised, alternate) >= 3)
        #expect(Tokens.distinct(.black, from: [white], toward: .white) == .black)
    }

    @Test(.isolatedSettings) func paletteThemesKeepTheirSelection() {
        Settings.shared.updateAppearance { $0.themeName = "Breeze Light" }
        #expect(rgb(Theme.selection, dark: false) == [66, 132, 210])
        #expect(rgb(Theme.selectionText, dark: false) == [26, 30, 44])
    }

    private func color(_ c: [Int]) -> NSColor {
        NSColor(srgbRed: CGFloat(c[0]) / 255, green: CGFloat(c[1]) / 255, blue: CGFloat(c[2]) / 255, alpha: 1)
    }
}
