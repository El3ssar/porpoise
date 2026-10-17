import AppKit
import PorpoiseCore
import PorpoiseServices

/// The cloud badge drawn on item icons. Its color follows what is underneath: white on dark icons and
/// previews, blue on light ones (paper documents, bright photos), each with a soft opposite halo.
enum CloudBadge {
    /// Measured brightness per image (held weakly: an address reused by a new image must not inherit
    /// an old result) and per badge position within it.
    private static let cache = NSMapTable<NSImage, NSMutableDictionary>.weakToStrongObjects()

    /// Average brightness under the badge: the icon's pixels, with the view color where the icon is transparent.
    static func backgroundIsLight(_ image: NSImage?, imageRect: CGRect, badge: CGRect, behind: NSColor) -> Bool {
        guard let image, imageRect.width > 0, imageRect.height > 0 else { return false }
        // Badge position as a fraction of the image (flipped view coordinates → image coordinates).
        let fx = (badge.minX - imageRect.minX) / imageRect.width, fw = badge.width / imageRect.width
        let fyTop = (badge.minY - imageRect.minY) / imageRect.height, fh = badge.height / imageRect.height
        let key = "\(Int(fx * 20))|\(Int(fyTop * 20))|\(Int(fw * 20))" as NSString
        let perImage =
            cache.object(forKey: image)
            ?? {
                let d = NSMutableDictionary()
                cache.setObject(d, forKey: image)
                return d
            }()
        if let c = perImage[key] as? Bool { return c }
        let n = 8
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Map the badge's part of the image onto the n×n bitmap.
        let sz = image.size
        let src = CGRect(x: fx * sz.width, y: (1 - fyTop - fh) * sz.height, width: fw * sz.width, height: fh * sz.height)
        image.draw(in: CGRect(x: 0, y: 0, width: n, height: n), from: src, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let bgc = behind.usingColorSpace(.deviceRGB) ?? .black
        let bgL = 0.299 * bgc.redComponent + 0.587 * bgc.greenComponent + 0.114 * bgc.blueComponent
        // The icon's own pixels decide (the badge sits on the icon); the view shows through only where it's mostly empty.
        var iconL: CGFloat = 0, cover: CGFloat = 0
        for x in 0..<n {
            for y in 0..<n {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let a = c.alphaComponent
                guard a > 0.05 else { continue }
                iconL += a * min(1, (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) / a)
                cover += a
            }
        }
        let coverage = cover / CGFloat(n * n)
        let lum = coverage > 0.2 ? iconL / cover : (iconL + (CGFloat(n * n) - cover) * bgL) / CGFloat(n * n)
        let light = lum > 0.55
        perImage[key] = light
        return light
    }

    /// A filled symbol in `tint` on a white disc (reads on any icon): the edit states of Drive files.
    static func draw(symbol: String, tint: NSColor, in r: CGRect) {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowBlurRadius = max(1, r.height * 0.1)
        sh.shadowOffset = .zero
        sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
        sh.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.06, dy: r.height * 0.06)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let conf = NSImage.SymbolConfiguration(pointSize: r.height, weight: .semibold).applying(.init(paletteColors: [.white, tint]))
        let img = base.withSymbolConfiguration(conf) ?? base
        let s = img.size
        let sc = min(r.width / max(s.width, 1), r.height / max(s.height, 1))
        let w = s.width * sc, h = s.height * sc
        img.draw(
            in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
    }

    static func draw(_ state: CloudState, in r: CGRect, onLight: Bool) {
        if let p = state.progress {
            var upload = false
            if case .uploading = state { upload = true }
            drawProgress(p, upload: upload, in: r, onLight: onLight)
            return
        }
        if case .error = state {
            draw(symbol: "exclamationmark.circle.fill", tint: Theme.transferDanger, in: r)
            return
        }
        guard let name = state.symbol, let base = NSImage(systemSymbolName: name, accessibilityDescription: state.help) else { return }
        let color = tint(onLight: onLight)
        let conf = NSImage.SymbolConfiguration(pointSize: r.height * 0.8, weight: .semibold).applying(.init(paletteColors: [color]))
        let img = base.withSymbolConfiguration(conf) ?? base
        let s = img.size
        let sc = min(r.width / max(s.width, 1), r.height / max(s.height, 1))
        let w = s.width * sc, h = s.height * sc
        NSGraphicsContext.saveGraphicsState()
        halo(onLight: onLight, r: r).set()
        img.draw(
            in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func tint(onLight: Bool) -> NSColor { onLight ? NSColor(srgbRed: 0.10, green: 0.42, blue: 0.86, alpha: 1) : .white }

    private static func halo(onLight: Bool, r: CGRect) -> NSShadow {
        let sh = NSShadow()
        sh.shadowBlurRadius = max(1.5, r.height * 0.14)
        sh.shadowOffset = .zero
        sh.shadowColor = onLight ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.85)
        return sh
    }

    /// A transfer with known progress: a ring that fills clockwise from the top around a small arrow.
    static func drawProgress(_ p: Double, upload: Bool, in r: CGRect, onLight: Bool) {
        let color = tint(onLight: onLight)
        let ring = r.insetBy(dx: r.width * 0.12, dy: r.height * 0.12)
        let lw = max(1.5, r.width * 0.12)
        NSGraphicsContext.saveGraphicsState()
        halo(onLight: onLight, r: r).set()
        let track = NSBezierPath(ovalIn: ring)
        track.lineWidth = lw
        color.withAlphaComponent(0.35).setStroke()
        track.stroke()
        // Flipped view: angles run clockwise from the right; start at the top.
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: CGPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, startAngle: -90,
            endAngle: -90 + 360 * CGFloat(max(0.02, min(1, p))), clockwise: false)
        arc.lineWidth = lw
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
        if let arrow = NSImage(systemSymbolName: upload ? "arrow.up" : "arrow.down", accessibilityDescription: nil) {
            let conf = NSImage.SymbolConfiguration(pointSize: ring.height * 0.5, weight: .bold).applying(.init(paletteColors: [color]))
            let img = arrow.withSymbolConfiguration(conf) ?? arrow
            let s = img.size
            img.draw(
                in: CGRect(x: ring.midX - s.width / 2, y: ring.midY - s.height / 2, width: s.width, height: s.height), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
