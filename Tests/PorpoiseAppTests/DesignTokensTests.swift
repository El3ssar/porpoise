import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import Testing

@testable import Porpoise

/// The design tokens of DESIGN-CONTRACT.md: the type scale and its one API.
@Suite(.serialized, .isolatedSettings) @MainActor struct DesignTokensTests {
    /// Every style has its size and weight; main-window content follows Settings › font size, dialogs keep macOS's sizes.
    @Test func textStylesScaleOnlyWhenAsked() {
        #expect(Tokens.font(.body).pointSize == 13 && Tokens.font(.callout).pointSize == 12 && Tokens.font(.footnote).pointSize == 11)
        #expect(Tokens.font(.largeTitle).pointSize == 26 && Tokens.font(.caption).pointSize == 10)
        #expect(Tokens.font(.mono).isFixedPitch && Tokens.font(.footnote, digits: true).pointSize == 11)
        Settings.shared.updateAppearance { $0.uiFontSize = 16 }
        #expect(Tokens.font(.body, scaled: true).pointSize == 16 && Tokens.font(.title3, scaled: true).pointSize == 18)
        #expect(Tokens.font(.callout, scaled: true).pointSize == 15)
        for style in Tokens.TextStyle.allCases { #expect(Tokens.font(style).pointSize == style.size) }
        // A weight given replaces the style's.
        let regular = Tokens.font(.headline, weight: .regular).fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        #expect((regular?[.weight] as? CGFloat ?? 1) < 0.1)
    }
}

extension DesignTokensTests {
    /// The grey selection of a window that isn't key stands out from both dark rows (it was about 1.5:1).
    @Test func theUnemphasizedSelectionStandsOutInDark() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        var selection = NSColor.black, rows: [NSColor] = []
        dark.performAsCurrentDrawingAppearance {
            selection = Tokens.unemphasizedSelection.usingColorSpace(.sRGB) ?? .black
            rows = [Theme.viewBackground, Theme.viewAlternate].map { $0.usingColorSpace(.sRGB) ?? .black }
        }
        for row in rows { #expect(Tokens.contrast(selection, row) >= 1.8) }
        // Light keeps macOS's own grey.
        var light = NSColor.black, system = NSColor.white
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            light = Tokens.unemphasizedSelection.usingColorSpace(.sRGB) ?? .black
            system = NSColor.unemphasizedSelectedContentBackgroundColor.usingColorSpace(.sRGB) ?? .white
        }
        #expect(Tokens.themeColor(light) == Tokens.themeColor(system))
    }
}
