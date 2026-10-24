import AppKit

/// An image view for a file's picture (a photo, a PDF page, a video frame): drawn with rounded corners and a hairline
/// edge, as every preview surface is (DESIGN-CONTRACT P1). An icon (no picture) is drawn bare, as AppKit draws it.
final class PreviewImageView: NSImageView {
    /// The image is the file's own picture, not an icon.
    var isPicture = false {
        didSet { if isPicture != oldValue { needsDisplay = true } }
    }

    /// Where the image is drawn: fitted into the view, centred, as `.scaleProportionallyUpOrDown` puts it.
    var pictureRect: CGRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isPicture, let image else { return super.draw(dirtyRect) }
        let rect = pictureRect
        let radius = min(Tokens.Radius.medium, rect.width / 4, rect.height / 4)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        // A hairline edge, so a pale picture doesn't melt into the panel.
        Theme.separator.setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        edge.lineWidth = 0.5
        edge.stroke()
    }
}
