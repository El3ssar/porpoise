import AppKit
import PorpoiseCore
import PorpoiseServices

/// iCloud Drive / File Provider (Google Drive, OneDrive, Dropbox…) state of an item, as Finder shows it.
enum CloudState: Equatable {
    case local          // not a cloud item, or downloaded and in sync (no badge, like Finder)
    case cloudOnly      // only in the cloud: Finder's cloud-with-arrow
    case downloading
    case uploading

    private static let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                    .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey]

    static func of(_ url: URL) -> (state: CloudState, isCloud: Bool) {
        guard url.isFileURL, let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true else { return (.local, false) }
        if v.ubiquitousItemIsDownloading == true { return (.downloading, true) }
        if v.ubiquitousItemIsUploading == true { return (.uploading, true) }
        if v.ubiquitousItemDownloadingStatus == .notDownloaded { return (.cloudOnly, true) }
        return (.local, true)
    }

    var symbol: String? {
        switch self {
        case .local: return nil
        case .cloudOnly: return "icloud.and.arrow.down"
        case .downloading: return "arrow.down.circle.dotted"
        case .uploading: return "icloud.and.arrow.up"
        }
    }

    var help: String {
        switch self {
        case .local: return ""
        case .cloudOnly: return "In the cloud only. Click to download."
        case .downloading: return "Downloading…"
        case .uploading: return "Uploading…"
        }
    }
}

enum CloudActions {
    /// Download Now: files directly, folders with everything inside.
    static func download(_ urls: [URL]) {
        let fm = FileManager.default
        DispatchQueue.global(qos: .userInitiated).async {
            for u in urls {
                try? fm.startDownloadingUbiquitousItem(at: u)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
                   let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isUbiquitousItemKey], options: []) {
                    for case let c as URL in e { try? fm.startDownloadingUbiquitousItem(at: c) }
                }
            }
            DispatchQueue.main.async { FileOperationsController.notifyChanged(urls) }
        }
    }

    /// Remove Download: keeps the item in the cloud, frees the local copy.
    static func evict(_ urls: [URL], window: NSWindow?) {
        var failed: [String] = []
        for u in urls {
            do { try FileManager.default.evictUbiquitousItem(at: u) } catch { failed.append("“\(u.lastPathComponent)”: \(error.localizedDescription)") }
        }
        FileOperationsController.notifyChanged(urls)
        if !failed.isEmpty {
            let a = NSAlert()
            a.messageText = "Some downloads could not be removed."
            a.informativeText = failed.prefix(6).joined(separator: "\n")
            a.window.appearance = NSAppearance(named: .darkAqua)
            if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
        }
    }
}

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
        let perImage = cache.object(forKey: image) ?? {
            let d = NSMutableDictionary()
            cache.setObject(d, forKey: image)
            return d
        }()
        if let c = perImage[key] as? Bool { return c }
        let n = 8
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
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
        for x in 0..<n { for y in 0..<n {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let a = c.alphaComponent
            guard a > 0.05 else { continue }
            iconL += a * min(1, (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) / a)
            cover += a
        } }
        let coverage = cover / CGFloat(n * n)
        let lum = coverage > 0.2 ? iconL / cover : (iconL + (CGFloat(n * n) - cover) * bgL) / CGFloat(n * n)
        let light = lum > 0.55
        perImage[key] = light
        return light
    }

    static func draw(_ state: CloudState, in r: CGRect, onLight: Bool) {
        guard let name = state.symbol, let base = NSImage(systemSymbolName: name, accessibilityDescription: state.help) else { return }
        let color: NSColor = onLight ? NSColor(srgbRed: 0.10, green: 0.42, blue: 0.86, alpha: 1) : .white
        let conf = NSImage.SymbolConfiguration(pointSize: r.height * 0.8, weight: .semibold).applying(.init(paletteColors: [color]))
        let img = base.withSymbolConfiguration(conf) ?? base
        let s = img.size
        let sc = min(r.width / max(s.width, 1), r.height / max(s.height, 1))
        let w = s.width * sc, h = s.height * sc
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowBlurRadius = max(1.5, r.height * 0.14)
        sh.shadowOffset = .zero
        sh.shadowColor = onLight ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.85)
        sh.set()
        img.draw(in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
