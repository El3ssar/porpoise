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

    private func close(_ a: [Int], _ b: [Int], within tolerance: Int = 3) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= tolerance } }

    @Test(.isolatedSettings) func defaultThemeResolvesToSystemColours() {
        #expect(Tokens.isNative && Settings.shared.appearancePreferences.iconTheme == "Native macOS")
        for dark in [false, true] {
            #expect(rgb(Theme.viewBackground, dark: dark) == rgb(.controlBackgroundColor, dark: dark))
            #expect(rgb(Theme.windowBackground, dark: dark) == rgb(.windowBackgroundColor, dark: dark))
            #expect(rgb(Theme.windowText, dark: dark) == rgb(.labelColor, dark: dark))
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
        let material = TintedMaterialView(material: .sidebar, tint: Theme.sidebarBackground, alpha: 0.70)
        func tintAlpha() -> CGFloat {
            Theme.lookChanged()
            return material.layer?.sublayers?.compactMap(\.backgroundColor).first?.alpha ?? -1
        }
        #expect(tintAlpha() == 0)
        Settings.shared.updateAppearance { $0.themeName = "Breeze Dark" }
        #expect(abs(tintAlpha() - 0.70) < 0.001)
    }

    @Test(.isolatedSettings) func increaseContrastStrengthensPaletteLines() {
        Settings.shared.updateAppearance { $0.themeName = "Breeze Light" }
        let saved = Theme.systemIncreasesContrast
        defer { Theme.systemIncreasesContrast = saved }
        func measure() -> [[Int]] {
            [Theme.separator, Theme.frame, Theme.hairline, Theme.disabledText, Theme.itemHoverFill, Theme.placesSelectedFill].map {
                var c = $0
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { c = $0.usingColorSpace(.sRGB) ?? $0 }
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
}
