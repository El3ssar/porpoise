import AppKit
import PorpoiseCore

/// How full a disk or a cloud account is. One table says how that shows wherever a capacity bar is drawn (the
/// sidebar, Settings › Accounts, the status bar): the accent color, amber past 80 % used, red past 95 %.
struct StorageCapacity: Equatable {
    let used: Int64
    let total: Int64
    init(used: Int64, total: Int64) {
        self.used = max(0, used)
        self.total = max(0, total)
    }
    init(free: Int64, total: Int64) { self.init(used: total - free, total: total) }

    var free: Int64 { max(0, total - used) }
    var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }

    enum Severity { case normal, nearlyFull, full }
    var severity: Severity { Self.severity(fraction) }
    static func severity(_ fraction: Double) -> Severity { fraction > 0.95 ? .full : fraction > 0.8 ? .nearlyFull : .normal }

    /// "786 GB free out of 1 TB (21% used)".
    var summary: String { "\(FileFormat.size(free)) free out of \(FileFormat.size(total)) (\(Int(fraction * 100))% used)" }
}

/// The capacity bar's drawing, for views that draw it among other things (the sidebar's rows, the status bar).
enum CapacityBar {
    /// `flat`: a slim capsule (the sidebar, Settings). `raised`: a little gradient and a top highlight (the status bar).
    enum Look { case flat, raised }

    static func color(_ severity: StorageCapacity.Severity) -> NSColor {
        switch severity {
        case .normal: return Theme.selectionAlternate
        case .nearlyFull: return Theme.transferChanged
        case .full: return Theme.negativeText
        }
    }

    /// The track across `bar` and the used part filled from the left (never thinner than it is tall, so a little use
    /// still shows).
    static func draw(fraction: Double, in bar: CGRect, look: Look = .flat) {
        let fraction = min(1, max(0, fraction)), radius = bar.height / 2
        Theme.windowText.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        let severity = StorageCapacity.severity(fraction)
        let fill = CGRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * CGFloat(fraction)), height: bar.height)
        guard look == .raised else {
            color(severity).setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
            return
        }
        let colors: [NSColor]
        switch severity {
        case .normal: colors = [Theme.selection.lighter(150), Theme.selectionAlternate]
        case .nearlyFull: colors = [Theme.selectionAlternate, color(.nearlyFull)]
        case .full: colors = [Theme.neutralText.mixed(with: .systemOrange, 0.6), color(.full)]
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).addClip()
        NSGradient(colors: colors)?.draw(in: fill, angle: 0)
        // Soft top highlight for a little depth.
        NSColor.white.withAlphaComponent(NSAppearance.currentDrawing().isDark ? 0.18 : 0.35).setFill()
        CGRect(x: fill.minX, y: fill.minY, width: fill.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A capacity bar on its own (Settings › Accounts).
final class CapacityBarView: NSView {
    var fraction: Double { didSet { needsDisplay = true } }
    init(fraction: Double) {
        self.fraction = fraction
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { CapacityBar.draw(fraction: fraction, in: bounds) }
}
