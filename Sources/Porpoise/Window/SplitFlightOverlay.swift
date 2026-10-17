import AppKit

/// Draws copies of a pane's items flying to their places in the other pane while the split view opens or closes.
/// It sits above both panes and takes no clicks.
final class SplitFlightOverlay: NSView {
    struct Flight {
        /// The item's transition key (`ItemListView.transitionKey`).
        let key: String
        /// The item as the pane it leaves draws it.
        let image: CGImage
        /// The item as the pane it lands in draws it (its own icon size, row height): the copy turns into it on the
        /// way, so it lands as exactly what's drawn there. Nil: the copy keeps its picture.
        let landing: CGImage?
    }

    var flights: [Flight] = []
    /// Where the original is drawn at this moment, and where its copy lands, in the overlay's coordinates (each with
    /// its own size). Both move while the panes do, so the copy leaves exactly from its original and arrives exactly
    /// on its cell.
    var source: (String) -> CGRect? = { _ in nil }
    var target: (String) -> CGRect? = { _ in nil }
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }
    /// The sizes the first copy was drawn at, frame by frame (the debug bridge and tests check they only grow or only
    /// shrink, and end at the landing cell's).
    private(set) var drawnSizes: [CGSize] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where a copy is drawn at `progress` `p`: position and size both go from its original to its cell.
    static func frame(from: CGRect, to: CGRect, progress p: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p,
            width: from.width + (to.width - from.width) * p, height: from.height + (to.height - from.height) * p)
    }

    /// How much of the landing picture shows at `p`: the leaving one holds through the start, the landing one has
    /// taken over well before the end (both are drawn at the copy's size, so neither looks stretched for long).
    static func landingShare(_ p: CGFloat) -> CGFloat {
        let x = min(1, max(0, (p - 0.15) / 0.6))
        return x * x * (3 - 2 * x)
    }

    override func draw(_ dirty: NSRect) {
        let p = progress
        let share = Self.landingShare(p)
        for (n, f) in flights.enumerated() {
            guard let from = source(f.key), let to = target(f.key) else { continue }
            let r = Self.frame(from: from, to: to, progress: p)
            if n == 0 { drawnSizes.append(r.size) }
            if f.landing == nil || share < 1 {
                NSImage(cgImage: f.image, size: from.size).draw(
                    in: r, from: .zero, operation: .sourceOver, fraction: f.landing == nil ? 1 : 1 - share, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high])
            }
            if let landing = f.landing, share > 0 {
                NSImage(cgImage: landing, size: to.size).draw(
                    in: r, from: .zero, operation: .sourceOver, fraction: share, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high])
            }
        }
    }
}
