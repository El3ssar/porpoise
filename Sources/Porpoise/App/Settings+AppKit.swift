import AppKit
import PorpoiseServices

extension Settings {
    /// Font for item labels (Icons/Compact/Details).
    var labelFont: NSFont {
        let size = CGFloat(labelFontSize)
        if !labelFontName.isEmpty, let f = NSFont(name: labelFontName, size: size) { return f }
        return .systemFont(ofSize: size)
    }
}
