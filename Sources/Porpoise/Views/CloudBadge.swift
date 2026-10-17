import AppKit
import PorpoiseCore
import PorpoiseServices

/// An item's one cloud badge (iCloud Drive, File Provider and connected accounts alike): in the list modes a status
/// glyph after the name, as Finder shows it; in Icons a small disc on the icon's lower right corner.
enum CloudBadge {
    /// What the glyph is drawn with.
    struct Look: Equatable {
        var symbol: String
        var tint: NSColor
        /// A ring filling to this fraction around a small arrow (a transfer whose progress is known).
        var progress: Double?
        var upload = false
        /// The inner glyph of a filled symbol (the arrow in arrow.down.circle.fill): white on the tinted disc, the
        /// selection's color on selected rows.
        var knock: NSColor = .white
    }

    /// The glyph and its color; nil: no badge. Selected rows draw in the selection's text color.
    static func look(_ kind: CloudBadgeKind, selected: Bool = false) -> Look? {
        let quiet = selected ? Theme.selectionText : Theme.viewTextInactive
        let accent = selected ? Theme.selectionText : Theme.activeText
        let danger = selected ? Theme.selectionText : Theme.transferDanger
        let knock = selected ? Theme.selection : NSColor.white
        return look(kind, quiet: quiet, accent: accent, danger: danger, selected: selected).map {
            var l = $0
            l.knock = knock
            return l
        }
    }

    private static func look(_ kind: CloudBadgeKind, quiet: NSColor, accent: NSColor, danger: NSColor, selected: Bool) -> Look? {
        switch kind {
        case .none: return nil
        case .edit(let mark):
            let tint = mark.needsAttention ? danger : mark == .saved ? (selected ? Theme.selectionText : Theme.transferPositive) : accent
            return Look(symbol: mark.symbol, tint: tint)
        case .cloud(let state):
            switch state {
            case .local: return nil
            case .cloudOnly: return Look(symbol: "icloud.and.arrow.down", tint: quiet)
            case .downloading(let p): return Look(symbol: "arrow.down.circle.dotted", tint: accent, progress: p)
            case .uploading(let p): return Look(symbol: "icloud.and.arrow.up", tint: accent, progress: p, upload: true)
            case .error: return Look(symbol: "exclamationmark.circle.fill", tint: danger)
            }
        }
    }

    /// The text for the tooltip and the status bar.
    static func help(_ kind: CloudBadgeKind, of url: URL) -> String? {
        switch kind {
        case .none: return nil
        case .edit(let mark): return mark.note(CloudAccounts.shared.providerTitle(for: url))
        case .cloud(let state): return state == .local ? nil : state.help
        }
    }

    /// List modes: the glyph alone, at text size, in `r`.
    static func drawGlyph(_ look: Look, in r: CGRect) {
        if let p = look.progress {
            drawRing(p, upload: look.upload, tint: look.tint, track: look.tint.withAlphaComponent(0.25), in: r)
        } else {
            drawSymbol(look.symbol, tint: look.tint, knock: look.knock, in: r)
        }
    }

    /// Icons: the glyph on a disc of the view's color with a soft halo, so it reads on any icon or preview.
    static func drawBadge(_ look: Look, in r: CGRect, disc: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowBlurRadius = max(1.5, r.height * 0.12)
        sh.shadowOffset = NSSize(width: 0, height: -max(0.5, r.height * 0.03))
        sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
        sh.set()
        disc.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSGraphicsContext.restoreGraphicsState()
        drawGlyph(look, in: r.insetBy(dx: r.width * 0.14, dy: r.height * 0.14))
    }

    private static func drawSymbol(_ name: String, tint: NSColor, knock: NSColor? = nil, in r: CGRect) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        // Filled symbols have two layers: the glyph (knock), then its disc (tint).
        let colors = name.hasSuffix(".fill") ? [knock ?? .white, tint] : [tint]
        let conf = NSImage.SymbolConfiguration(pointSize: r.height, weight: .semibold).applying(.init(paletteColors: colors))
        let img = base.withSymbolConfiguration(conf) ?? base
        let s = img.size
        let sc = min(r.width / max(s.width, 1), r.height / max(s.height, 1))
        let w = s.width * sc, h = s.height * sc
        img.draw(
            in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
    }

    /// A ring that fills clockwise from the top around a small arrow.
    private static func drawRing(_ p: Double, upload: Bool, tint: NSColor, track: NSColor, in r: CGRect) {
        let lw = max(1.5, r.width * 0.12)
        let ring = r.insetBy(dx: lw / 2, dy: lw / 2)
        let circle = NSBezierPath(ovalIn: ring)
        circle.lineWidth = lw
        track.setStroke()
        circle.stroke()
        // Flipped view: start at the top and go clockwise.
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: CGPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, startAngle: -90,
            endAngle: -90 + 360 * CGFloat(max(0.03, min(1, p))), clockwise: false)
        arc.lineWidth = lw
        arc.lineCapStyle = .round
        tint.setStroke()
        arc.stroke()
        let inner = ring.insetBy(dx: ring.width * 0.2, dy: ring.height * 0.2)
        drawSymbol(upload ? "arrow.up" : "arrow.down", tint: tint, in: inner)
    }
}
