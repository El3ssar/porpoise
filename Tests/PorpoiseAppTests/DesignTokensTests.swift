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
