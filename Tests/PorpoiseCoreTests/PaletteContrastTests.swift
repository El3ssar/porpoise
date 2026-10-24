import Foundation
import Testing

@testable import PorpoiseCore

/// Every built-in palette reads (DESIGN-CONTRACT C4, WCAG 2 AA): text and secondary text at 4.5:1 on the view and the
/// window, text at 4.5:1 on the selection as palette themes draw it (32 % over the view), and the accent at 3:1 against
/// the view, as a control's state colour must be.
struct PaletteContrastTests {
    private func luminance(_ c: ThemeColor) -> Double {
        func linear(_ v: Int) -> Double {
            let x = Double(v) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    private func contrast(_ a: ThemeColor, _ b: ThemeColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func mix(_ a: ThemeColor, _ b: ThemeColor, _ t: Double) -> ThemeColor {
        func m(_ x: Int, _ y: Int) -> Int { Int((Double(x) * (1 - t) + Double(y) * t).rounded()) }
        return ThemeColor(m(a.red, b.red), m(a.green, b.green), m(a.blue, b.blue))
    }

    @Test(arguments: AppearanceTheme.builtIns) func paletteMeetsAA(_ theme: AppearanceTheme) {
        let view = theme[.viewBackground], window = theme[.windowBackground]
        for (role, minimum) in [(ThemeRole.text, 4.5), (.secondaryText, 4.5)] {
            for (name, background) in [("view", view), ("window", window)] {
                let ratio = contrast(theme[role], background)
                #expect(ratio >= minimum, "\(theme.name): \(role) on the \(name) is \(ratio):1")
            }
        }
        let selected = mix(view, theme[.selection], 0.32)
        #expect(contrast(theme[.text], selected) >= 4.5, "\(theme.name): text on the selection")
        #expect(contrast(theme[.accent], view) >= 3, "\(theme.name): accent on the view")
    }
}
