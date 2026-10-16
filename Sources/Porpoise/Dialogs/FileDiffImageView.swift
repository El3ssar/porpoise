import AppKit
import ImageIO

struct FileDiffImages {
    let left: CGImage
    let right: CGImage
    let difference: CGImage?
    let changedPercent: Double?
    let sampled: Bool
    static func load(_ left: URL, _ right: URL) throws -> FileDiffImages {
        func image(_ url: URL) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return image
        }
        let a = try image(left), b = try image(right)
        let fullW = max(a.width, b.width), fullH = max(a.height, b.height)
        // Display diff is bounded at 16M pixels. The label makes sampling explicit for huge photographs.
        let factor = min(1, sqrt(16_000_000 / Double(fullW * fullH))), w = max(1, Int(Double(fullW) * factor)),
            h = max(1, Int(Double(fullH) * factor))
        let space = CGColorSpaceCreateDeviceRGB(), options = CGImageAlphaInfo.premultipliedLast.rawValue
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: options)!
                ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: Double(image.width) * factor, height: Double(image.height) * factor))
            }; return bytes
        }
        let x = pixels(a), y = pixels(b); var output = [UInt8](repeating: 0, count: x.count), changed = 0
        for p in stride(from: 0, to: output.count, by: 4) {
            var different = false
            for c in 0..<4 { let d = abs(Int(x[p + c]) - Int(y[p + c])); different = different || d > 0; if c < 3 { output[p + c] = UInt8(d) } }
            // An alpha-only change must be visible too.
            let alpha = UInt8(abs(Int(x[p + 3]) - Int(y[p + 3])))
            for c in 0..<3 { output[p + c] = max(output[p + c], alpha) }; output[p + 3] = 255
            if different { changed += 1 }
        }
        let provider = CGDataProvider(data: Data(output) as CFData)!
        let diff = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: options),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        return FileDiffImages(left: a, right: b, difference: diff, changedPercent: Double(changed) / Double(w * h) * 100, sampled: factor < 1)
    }
}

final class FileDiffImageView: NSView {
    var images: FileDiffImages?
    var mode = 0 { didSet { needsDisplay = true } }
    var opacity: CGFloat = 0.5 { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1 { didSet { zoom = min(16, max(0.1, zoom)); needsDisplay = true } }
    var pan = NSPoint.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.viewBackground.setFill(); bounds.fill()
        guard let images else { return }
        let half = bounds.width / 2
        if mode == 0 {
            draw(images.left, in: NSRect(x: 0, y: 0, width: half, height: bounds.height), images: images)
            draw(images.right, in: NSRect(x: half, y: 0, width: half, height: bounds.height), images: images)
            Theme.separator.setFill(); NSRect(x: half, y: 0, width: 1, height: bounds.height).fill()
        } else if mode == 1 {
            draw(images.left, in: bounds, images: images)
            draw(images.right, in: bounds, images: images, alpha: opacity)
        } else if let diff = images.difference {
            NSColor.black.setFill(); bounds.fill(); draw(diff, in: bounds, images: images, difference: true)
        }
    }
    private func draw(_ image: CGImage, in rect: NSRect, images: FileDiffImages, alpha: CGFloat = 1, difference: Bool = false) {
        let maxW = CGFloat(max(images.left.width, images.right.width)), maxH = CGFloat(max(images.left.height, images.right.height))
        let scale = min((rect.width - 48) / maxW, (rect.height - 64) / maxH) * zoom
        let x = rect.midX - maxW * scale / 2 + pan.x, y = rect.midY - maxH * scale / 2 + pan.y
        let target = NSRect(
            x: x, y: y, width: (difference ? maxW : CGFloat(image.width)) * scale, height: (difference ? maxH : CGFloat(image.height)) * scale)
        NSGraphicsContext.saveGraphicsState(); rect.clip()
        NSImage(cgImage: image, size: .zero).draw(in: target, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func magnify(with event: NSEvent) { zoom *= 1 + event.magnification }
    override func scrollWheel(with event: NSEvent) { pan.x -= event.scrollingDeltaX; pan.y -= event.scrollingDeltaY; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " && mode == 1 { opacity = opacity < 0.5 ? 1 : 0 } else { super.keyDown(with: event) }
    }
}
