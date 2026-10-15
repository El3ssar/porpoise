import AppKit
import PorpoiseCore

/// A keyboard-accessible native button with a miniature browser palette instead of a theme-name popup.
final class ThemePreviewButton: NSButton {
    private var palette: () -> AppearanceTheme = { AppearanceTheme.builtIns[0] }
    private var select: () -> Void = {}
    convenience init(title: String, theme: @escaping () -> AppearanceTheme, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title; palette = theme; select = action
        target = self; self.action = #selector(choose)
        setButtonType(.pushOnPushOff)
        isBordered = false
        setAccessibilityLabel(title)
    }
    @objc private func choose() { select() }
    override func draw(_ dirtyRect: NSRect) {
        let theme = palette()
        func color(_ role: ThemeRole) -> NSColor {
            let c = theme[role]
            return NSColor(srgbRed: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255, alpha: 1)
        }
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        color(.viewBackground).setFill(); border.fill()
        NSGraphicsContext.saveGraphicsState(); border.addClip()
        color(.sidebar).setFill(); NSRect(x: 1, y: 22, width: 29, height: bounds.height - 23).fill()
        for i in 0..<3 {
            color(.folderTint).setFill()
            NSBezierPath(roundedRect: NSRect(x: 41 + i * 31, y: 32, width: 19, height: 14), xRadius: 3, yRadius: 3).fill()
            color(.secondaryText).setFill(); NSRect(x: 42 + i * 31, y: 27, width: 17, height: 2).fill()
        }
        color(.windowBackground).setFill(); NSRect(x: 1, y: 1, width: bounds.width - 2, height: 21).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: state == .on ? .semibold : .regular),
            .foregroundColor: color(.text),
        ]
        let text = NSAttributedString(string: title, attributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: 5))
        NSGraphicsContext.restoreGraphicsState()
        (state == .on ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        border.lineWidth = state == .on ? 2 : 0.5; border.stroke()
    }
}
