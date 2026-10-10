import AppKit
import PorpoiseCore
import PorpoiseServices

/// Finder tag colours, and the dots drawn next to names.
extension FinderTags {
    static func color(_ index: Int) -> NSColor? {
        switch index {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return nil
        }
    }

    /// Overlapping dots, as Finder draws them next to names.
    static func drawDots(_ tags: [Tag], at origin: CGPoint, diameter d: CGFloat, background: NSColor) {
        let shown = tags.prefix(3)
        for (i, t) in shown.enumerated().reversed() {
            let r = CGRect(x: origin.x + CGFloat(i) * d * 0.55, y: origin.y, width: d, height: d)
            let path = NSBezierPath(ovalIn: r)
            background.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1)).fill()
            if let c = color(t.color) {
                c.setFill(); path.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke(); path.lineWidth = 1.2
                NSBezierPath(ovalIn: r.insetBy(dx: 0.6, dy: 0.6)).stroke()
            }
        }
    }

    static func dotsWidth(_ count: Int, diameter d: CGFloat) -> CGFloat {
        count == 0 ? 0 : d + CGFloat(min(count, 3) - 1) * d * 0.55
    }
}
