import AppKit

/// Draws copies of the left pane's items flying to their places in the right pane while the split view opens.
/// It sits above both panes and takes no clicks.
final class SplitFlightOverlay: NSView {
    struct Flight {
        /// The item's transition key (`ItemListView.transitionKey`).
        let key: String
        let image: CGImage
        /// Its size in points: the copy keeps it whatever the destination's cell is (never stretched).
        let size: CGSize
    }

    var flights: [Flight] = []
    /// Where the original is drawn at this moment, and where its copy lands, in the overlay's coordinates. Both
    /// move while the split opens (the left items glide to their new places, the right pane slides), so the copy
    /// leaves exactly from its original and arrives exactly on its cell.
    var source: (String) -> CGRect? = { _ in nil }
    var target: (String) -> CGRect? = { _ in nil }
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = progress
        for f in flights {
            guard let from = source(f.key), let to = target(f.key) else { continue }
            let r = CGRect(
                x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p,
                width: f.size.width, height: f.size.height)
            ctx.saveGState()
            NSImage(cgImage: f.image, size: f.size).draw(
                in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            ctx.restoreGState()
        }
    }
}
