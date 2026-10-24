import AppKit
import ImageIO
import PorpoiseServices

typealias FileDiffImages = ImageFileComparison

final class FileDiffImageView: NSView {
    var images: FileDiffImages?
    var mode = 0 { didSet { needsDisplay = true } }
    var opacity: CGFloat = 0.5 { didSet { needsDisplay = true; onOpacityChange?(opacity) } }
    var zoom: CGFloat = 1 { didSet { zoom = min(16, max(0.1, zoom)); needsDisplay = true } }
    var pan = NSPoint.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var onOpacityChange: ((CGFloat) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        Theme.viewBackground.setFill(); bounds.fill()
        guard let images else { return }
        let half = bounds.width / 2
        if mode == 0 {
            render([(images.left, 1)], in: NSRect(x: 0, y: 0, width: half - 12, height: bounds.height), images: images)
            render([(images.right, 1)], in: NSRect(x: half + 12, y: 0, width: half - 12, height: bounds.height), images: images)
        } else if mode == 1 {
            render([(images.left, 1), (images.right, opacity)], in: bounds, images: images)
        } else if let diff = images.difference {
            render([(diff, 1)], in: bounds, images: images, difference: true)
        }
    }
    private func render(_ layers: [(CGImage, CGFloat)], in rect: NSRect, images: FileDiffImages, difference: Bool = false) {
        let maxW = CGFloat(max(images.left.width, images.right.width)), maxH = CGFloat(max(images.left.height, images.right.height))
        let scale = min(rect.width / maxW, rect.height / maxH) * zoom
        let canvas = NSRect(
            x: rect.midX - maxW * scale / 2 + pan.x, y: rect.midY - maxH * scale / 2 + pan.y, width: maxW * scale, height: maxH * scale)
        NSGraphicsContext.saveGraphicsState(); rect.clip()
        let frame = NSBezierPath(roundedRect: canvas, xRadius: Tokens.Radius.row, yRadius: Tokens.Radius.row)
        NSGraphicsContext.saveGraphicsState(); frame.addClip()
        (difference ? NSColor.black : Theme.viewBackground).setFill(); canvas.fill()
        for (image, alpha) in layers {
            let target = NSRect(
                x: canvas.minX, y: canvas.minY, width: (difference ? maxW : CGFloat(image.width)) * scale,
                height: (difference ? maxH : CGFloat(image.height)) * scale)
            NSImage(cgImage: image, size: .zero).draw(
                in: target, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        Theme.frame.setStroke(); frame.lineWidth = 1; frame.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    override func magnify(with event: NSEvent) { zoom *= 1 + event.magnification }
    override func scrollWheel(with event: NSEvent) { pan.x -= event.scrollingDeltaX; pan.y -= event.scrollingDeltaY; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " && mode == 1 { opacity = opacity < 0.5 ? 1 : 0 } else { super.keyDown(with: event) }
    }
}
