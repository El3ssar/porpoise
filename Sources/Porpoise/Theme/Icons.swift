import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices
import UniformTypeIdentifiers

/// Loads Tela-circle-dark icons from the app bundle and recolors them the way KDE's KIconLoader does
/// (replacing the SVG "current-color-scheme" stylesheet with the active color scheme).
final class Icons {
    static let shared = Icons()

    /// Rendered icons by name, pixel size and state (and app icons by path). Bounded: continuous zoom asks for
    /// many sizes, and browsing /Applications (or any folder, with native icons) for many icons by path. By bytes
    /// too: each holds the bitmap it was last drawn as, a megabyte at the biggest sizes.
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 3000
        c.totalCostLimit = 96 << 20
        return c
    }()

    /// `looks`: bitmaps it holds once drawn (two for icons that follow light and dark), each at the screen's scale.
    private func store(_ image: NSImage, _ key: NSString, size: CGFloat, looks: Int = 1) {
        cache.setObject(image, forKey: key, cost: max(1, Int(size * size)) * 4 * 4 * looks)
    }
    /// Resolved Finder alias targets (nil: unresolvable).
    private let aliasTargets: NSCache<NSString, AliasTarget> = {
        let c = NSCache<NSString, AliasTarget>()
        c.countLimit = 1000
        return c
    }()
    private final class AliasTarget {
        let item: FileItem?
        init(_ item: FileItem?) { self.item = item }
    }

    private init() {
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] n in
            guard Self.redraws(after: n.object as? String) else { return }
            self?.cache.removeAllObjects()
            self?.flattened.removeAllObjects()
        }
    }

    /// Settings that change how icons are drawn (nil: every setting, after Restore Defaults). Others, such as Show
    /// Hidden Files, a panel's size or the saved session, leave the rendered icons as they are.
    static func redraws(after key: String?) -> Bool { key == nil || key == "appearance" || key == "appearancePreferences" }

    /// Icon image by freedesktop name. `selected` uses highlighted-text colors (like KDE's selected state). It draws
    /// in the colors of the look it's drawn in (light or dark), so menus and buttons holding it follow a change.
    func image(_ name: String, size: CGFloat, selected: Bool = false, folder: Bool = false) -> NSImage? {
        let px = Int(size)
        let preferences = Settings.shared.appearancePreferences
        let tintKey = Theme.paletteColor(.folderTint, dark: true).hex + Theme.paletteColor(.folderTint, dark: false).hex
        let key = "\(preferences.iconTheme)|\(preferences.folderVariant)|\(tintKey)|\(name)|\(px)|\(selected)|\(folder)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let url = IconTheme.shared.file(name, size: px) else { return nil }
        func render(dark: Bool) -> NSImage? {
            let source: NSImage?
            if url.pathExtension == "svg", let svg = try? String(contentsOf: url, encoding: .utf8) {
                // Resolve symbolic colours first. Folder artwork is then mapped as a whole, including fixed palettes.
                source = NSImage(data: Data(Self.recolor(svg, stylesheet: Theme.iconStylesheet(selected: selected, dark: dark)).utf8))
            } else {
                source = NSImage(contentsOf: url)
            }
            guard let source else { return nil }
            if folder || IconTheme.isFolderIcon(name) { return self.folderImage(source, size: size, dark: dark) }
            if url.deletingLastPathComponent().lastPathComponent == "mimetypes" { return Self.documentImage(source, size: size, dark: dark) }
            return source
        }
        guard let darkImg = render(dark: true), let lightImg = render(dark: false) else { return nil }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            (NSAppearance.currentDrawing().isDark ? darkImg : lightImg).draw(in: r)
            return true
        }
        store(img, key, size: size, looks: 2)
        return img
    }

    /// Icons drawn at another size on every frame (mid-zoom), as plain bitmaps per look: drawn as they are, an icon
    /// that follows light and dark renders itself again for each new size it's drawn at.
    private let flattened: NSCache<NSImage, Flattened> = {
        let c = NSCache<NSImage, Flattened>()
        c.countLimit = 1000
        c.totalCostLimit = 64 << 20
        return c
    }()
    private final class Flattened {
        var images: [String: NSImage] = [:]
        var bytes = 0
    }

    /// `image` as a bitmap of `scale` pixels per point, in the look it's drawn in now (cached).
    func flattened(_ image: NSImage, scale: CGFloat) -> NSImage {
        let look = "\(NSAppearance.currentDrawing().isDark)|\(scale)"
        let box = flattened.object(forKey: image) ?? Flattened()
        if let hit = box.images[look] { return hit }
        let px = max(1, Int(ceil(image.size.width * scale))), py = max(1, Int(ceil(image.size.height * scale)))
        guard
            let ctx = CGContext(
                data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: px, height: py))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return image }
        let flat = NSImage(cgImage: cg, size: image.size)
        box.images[look] = flat
        box.bytes += px * py * 4
        flattened.setObject(box, forKey: image, cost: box.bytes)
        return flat
    }

    /// A document (mimetype) icon: its near-white paper gets a soft edge in light, so it doesn't vanish on a white view,
    /// and is dimmed in dark, so a page isn't the brightest thing on screen.
    static func documentImage(_ source: NSImage, size: CGFloat, dark: Bool) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            NSGraphicsContext.saveGraphicsState()
            if !dark {
                let edge = NSShadow()
                edge.shadowBlurRadius = max(0.75, size / 40)
                edge.shadowOffset = NSSize(width: 0, height: -max(0.25, size / 96))
                edge.shadowColor = NSColor.black.withAlphaComponent(0.32)
                edge.set()
            }
            source.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
            if dark {
                NSColor.black.withAlphaComponent(Self.darkDocumentDim).setFill()
                r.fill(using: .sourceAtop)
            }
            return true
        }
    }

    /// How much darker document paper is drawn in dark: white paper ends at about 84 % of white.
    static let darkDocumentDim: CGFloat = 0.16

    private func folderImage(_ source: NSImage, size: CGFloat, dark: Bool) -> NSImage {
        let preferences = Settings.shared.appearancePreferences
        let tint = FolderColor.tint(Theme.paletteColor(.folderTint, dark: dark), variant: preferences.folderVariant)
        let pixels = max(1, Int(ceil(size * 2)))
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = rep.bitmapData else { return source }
        func sample(_ x: Int, _ y: Int) -> ThemeColor {
            let offset = y * rep.bytesPerRow + x * 4
            let alpha = max(1, Int(bytes[offset + 3]))
            return ThemeColor(
                Int(bytes[offset]) * 255 / alpha, Int(bytes[offset + 1]) * 255 / alpha,
                Int(bytes[offset + 2]) * 255 / alpha)
        }
        var chromatic = false
        for y in 0..<pixels {
            for x in 0..<pixels {
                let offset = y * rep.bytesPerRow + x * 4
                guard bytes[offset + 3] > 25 else { continue }
                let c = sample(x, y)
                if max(c.red, c.green, c.blue) - min(c.red, c.green, c.blue) > 40 {
                    chromatic = true
                    break
                }
            }
            if chromatic { break }
        }
        var mappedColors: [Int: ThemeColor] = [:]
        for y in 0..<pixels {
            for x in 0..<pixels {
                let offset = y * rep.bytesPerRow + x * 4
                let alpha = Int(bytes[offset + 3])
                guard alpha > 0 else { continue }
                let original = sample(x, y)
                let rgb = original.red << 16 | original.green << 8 | original.blue
                let mapped: ThemeColor
                if let cached = mappedColors[rgb] {
                    mapped = cached
                } else {
                    mapped = FolderColor.map(original, to: tint, monochrome: !chromatic || size <= 24)
                    mappedColors[rgb] = mapped
                }
                bytes[offset] = UInt8(mapped.red * alpha / 255)
                bytes[offset + 1] = UInt8(mapped.green * alpha / 255)
                bytes[offset + 2] = UInt8(mapped.blue * alpha / 255)
            }
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    static func recolor(_ svg: String, stylesheet: String) -> String {
        guard
            let r = svg.range(
                of: #"<style[^>]*id="current-color-scheme"[^>]*>[\s\S]*?</style>"#,
                options: .regularExpression),
            let open = svg[r].range(of: ">")
        else { return svg }
        let head = svg[r.lowerBound...open.lowerBound]
        return svg.replacingCharacters(in: r, with: head + stylesheet + "</style>")
    }

    // MARK: - File icons

    /// Icon name for a file item (freedesktop naming, Tela has them as mimetypes/places icons).
    func iconName(for item: FileItem) -> String {
        let has = IconTheme.shared.has
        if item.isBrowsableFolder { return IconTheme.folderIconName(item.url) }
        if item.fileExtension == "savedSearch" { return "folder-saved-search" }
        if item.isWebDocument, let kind = item.contentType?.split(separator: ".").last {
            // Google Docs and the like: the office icon of their kind (the view adds the link emblem: a web document).
            if has("application-vnd.google-apps.\(kind)") { return "application-vnd.google-apps.\(kind)" }
            let names = ["document": "x-office-document", "spreadsheet": "x-office-spreadsheet", "presentation": "x-office-presentation"]
            if let n = names[String(kind)], has(n) { return n }
            return has("x-office-drawing") && kind == "drawing" ? "x-office-drawing" : "text-html"
        }
        if let mime = item.mimeType {
            let direct = mime.replacingOccurrences(of: "/", with: "-")
            if has(direct) { return direct }
            if let alias = Self.mimeAliases[mime], has(alias) { return alias }
        }
        let ext = item.fileExtension.lowercased()
        if let e = Self.extensionIcons[ext], has(e) { return e }
        guard let t = item.utType else { return "unknown" }
        if t.conforms(to: .shellScript) { return "application-x-shellscript" }
        if t.conforms(to: .sourceCode) { return has("text-x-script") ? "text-x-script" : "text-x-generic" }
        if t.conforms(to: .image) { return "image-x-generic" }
        if t.conforms(to: .audio) { return "audio-x-generic" }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return "video-x-generic" }
        if t.conforms(to: .archive) { return "package-x-generic" }
        if t.conforms(to: .font) { return "font-x-generic" }
        if t.conforms(to: .unixExecutable) || t.conforms(to: .executable) { return "application-x-executable" }
        if t.conforms(to: .diskImage) { return "application-x-cd-image" }
        if t.conforms(to: .text) { return "text-x-generic" }
        if t.conforms(to: .presentation) { return "x-office-presentation" }
        if t.conforms(to: .spreadsheet) { return "x-office-spreadsheet" }
        return "unknown"
    }

    static let mimeAliases: [String: String] = [
        "application/x-sh": "application-x-shellscript",
        "text/x-shellscript": "application-x-shellscript",
        "application/zip": "application-zip",
        "application/x-tar": "application-x-tar",
        "application/gzip": "application-x-gzip",
        "application/x-bzip2": "application-x-bzip",
        "application/x-7z-compressed": "application-x-7z-compressed",
        "application/x-apple-diskimage": "application-x-apple-diskimage",
        "text/markdown": "text-markdown",
        "text/x-python-script": "text-x-python",
        "text/x-python": "text-x-python",
        "application/javascript": "application-javascript",
        "text/javascript": "application-javascript",
        "application/x-javascript": "application-javascript",
        "audio/mpeg": "audio-mpeg",
        "video/mp4": "video-mp4",
        "image/jpeg": "image-jpeg",
        "application/vnd.oasis.opendocument.spreadsheet": "x-office-spreadsheet",
        "application/vnd.oasis.opendocument.text": "x-office-document",
    ]

    static let extensionIcons: [String: String] = [
        "swift": "text-x-swift", "py": "text-x-python", "rs": "text-rust", "go": "text-x-go", "c": "text-x-csrc",
        "h": "text-x-chdr", "cpp": "text-x-c++src", "hpp": "text-x-c++hdr", "js": "application-javascript",
        "ts": "text-x-typescript", "json": "application-json", "md": "text-markdown", "yml": "application-x-yaml",
        "yaml": "application-x-yaml", "toml": "text-x-generic", "sh": "application-x-shellscript",
        "zsh": "application-x-shellscript", "rb": "application-x-ruby", "java": "text-x-java", "kt": "text-x-kotlin",
        "html": "text-html", "css": "text-css", "xml": "text-xml", "sql": "text-x-sql", "log": "text-x-log",
        "dmg": "application-x-apple-diskimage", "pkg": "application-x-xar", "iso": "application-x-cd-image",
        "lua": "text-x-lua", "php": "application-x-php", "dart": "text-x-dart", "csv": "text-csv",
        "pages": "x-office-document", "numbers": "x-office-spreadsheet", "key": "x-office-presentation",
    ]

    /// Image for a file item: real app icons for .app bundles (Mac), otherwise the Tela icon.
    func image(for item: FileItem, size: CGFloat, selected: Bool = false) -> NSImage {
        if Settings.shared.appearancePreferences.iconTheme == "Native macOS" {
            // Cached like app icons: asked for on every draw (hover fades redraw at 90 Hz), and a new image each
            // time also defeated CloudBadge's per-image cache.
            let p = Settings.shared.appearancePreferences
            let key = "native|\(item.url.path)|\(Int(size))|\(p.folderVariant)|\(Theme.paletteColor(.folderTint, dark: Theme.isDark).hex)" as NSString
            if let img = cache.object(forKey: key) { return img }
            var image = NSWorkspace.shared.icon(forFile: item.url.path)
            if item.isBrowsableFolder { image = folderImage(image, size: size, dark: Theme.isDark) }
            image.size = NSSize(width: size, height: size)
            store(image, key, size: size)
            return image
        }
        // Finder aliases look like their original (the view adds the link emblem).
        if item.isAliasFile, let t = aliasTarget(of: item), !t.isAliasFile { return image(for: t, size: size, selected: selected) }
        if item.isApplication || (item.isPackage && !item.isBrowsableFolder && item.fileExtension.lowercased() == "app") {
            let key = "app|\(item.url.path)|\(Int(size))" as NSString
            if let img = cache.object(forKey: key) { return img }
            let img = NSWorkspace.shared.icon(forFile: item.url.path)
            img.size = NSSize(width: size, height: size)
            store(img, key, size: size)
            return img
        }
        var name = iconName(for: item)
        // A special folder the theme draws only small (a glyph) shows as a plain folder when large, like its neighbours.
        if item.isBrowsableFolder, name != "folder", IconTheme.shared.isUpscaled(name, size: Int(size)) { name = "folder" }
        if name == "unknown" {
            // A type the theme has no icon for: the icon macOS declares for it (as Finder shows), else a generic file.
            if let t = item.utType, !t.isDynamic {
                let key = "type|\(t.identifier)|\(Int(size))"
                if let img = cache.object(forKey: key as NSString) { return img }
                let img = NSWorkspace.shared.icon(for: t)
                img.size = NSSize(width: size, height: size)
                store(img, key as NSString, size: size)
                return img
            }
            return image("application-octet-stream", size: size, selected: selected) ?? NSImage()
        }
        return image(name, size: size, selected: selected)
            ?? image("application-octet-stream", size: size, selected: selected) ?? NSImage()
    }

    private func aliasTarget(of item: FileItem) -> FileItem? {
        let key = item.url.path as NSString
        if let t = aliasTargets.object(forKey: key) { return t.item }
        let t = (try? URL(resolvingAliasFileAt: item.url, options: [.withoutUI, .withoutMounting])).flatMap(FileItem.load)
        aliasTargets.setObject(AliasTarget(t), forKey: key)
        return t
    }

    /// Small action icon for menus/buttons (16 px), nil when the theme lacks it.
    func menuIcon(_ name: String) -> NSImage? { image(name, size: 16) }
}
