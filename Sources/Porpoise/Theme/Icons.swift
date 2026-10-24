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
    /// Coloured-artwork decisions are shared by type; no per-file rasterisation in the draw path.
    private let nativePreservation: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 3000
        return c
    }()

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
            self?.nativePreservation.removeAllObjects()
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
        let image: NSImage?
        if name == "airdrop", ["Native macOS", Self.nativeColourTheme].contains(preferences.iconTheme) {
            image = airDropImage(size: size, selected: selected, systemGlyph: Self.systemAirDropGlyph)
        } else {
            image = portableImage(name, size: size, selected: selected, folder: folder)
        }
        guard let image else { return nil }
        store(image, key, size: size, looks: 2)
        return image
    }

    /// A missing system resource must leave the action visible. The optional source also permits a real fallback
    /// rendering test on systems where CoreTypes is present.
    func airDropImage(size: CGFloat, selected: Bool, systemGlyph: NSImage?) -> NSImage? {
        guard let source = systemGlyph else { return portableImage("airdrop", size: size, selected: selected, folder: false) }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState(); context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
            source.draw(in: rect)
            (selected ? Theme.selectionText : Theme.windowText).setFill()
            rect.fill(using: .sourceAtop)
            context.endTransparencyLayer(); context.restoreGState()
            return true
        }
    }

    private func portableImage(_ name: String, size: CGFloat, selected: Bool, folder: Bool) -> NSImage? {
        guard let url = IconTheme.shared.file(name, size: Int(size)) else { return nil }
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
        return img
    }

    /// Finder's own sidebar artwork, loaded from macOS rather than copied into the app. Public symbols are fallback
    /// for a system version without this CoreTypes resource; portable icon themes retain their bundled SVG.
    static let systemAirDropGlyph: NSImage? =
        NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarAirDrop.icns")
        ?? NSImage(systemSymbolName: "airdrop", accessibilityDescription: "AirDrop")

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
        let theme = Settings.shared.appearancePreferences.iconTheme
        if theme == "Native macOS" || theme == Self.nativeColourTheme {
            let native = nativeImage(for: item, size: size)
            return theme == Self.nativeColourTheme ? nativeColourImage(native, for: item, size: size) : native
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
                let shared = NSWorkspace.shared.icon(for: t)
                let img = shared.copy() as? NSImage ?? shared
                img.size = NSSize(width: size, height: size)
                store(img, key as NSString, size: size)
                return img
            }
            return image("application-octet-stream", size: size, selected: selected) ?? NSImage()
        }
        return image(name, size: size, selected: selected)
            ?? image("application-octet-stream", size: size, selected: selected) ?? NSImage()
    }

    /// The Native macOS theme: what Finder shows. A file on this Mac by its path (custom and app icons too); anything
    /// else, a cloud or remote item with no file here, by its type: asked by path, macOS answers a blank page for it.
    /// Cached like app icons: asked for on every draw (hover fades redraw at 90 Hz), and a new image each time also
    /// defeated CloudBadge's per-image cache.
    private func nativeImage(for item: FileItem, size: CGFloat) -> NSImage {
        let p = Settings.shared.appearancePreferences
        let local = item.url.isFileURL
        // Most items on this Mac show their type's icon: one icon (and one folder recolouring) per type and size,
        // not one per file, asked of macOS once.
        let type = local ? Self.sharedNativeType(for: item) : Self.nativeType(for: item)
        let source = type.map { "type|\($0.identifier)" } ?? "file|\(item.url.path)"
        let key = "native|\(source)|\(Int(size))|\(p.folderVariant)|\(Theme.paletteColor(.folderTint, dark: Theme.isDark).hex)" as NSString
        if let img = cache.object(forKey: key) { return img }
        var image = type.map { NSWorkspace.shared.icon(for: $0) } ?? NSWorkspace.shared.icon(forFile: item.url.path)
        // A copy: macOS may hand out one shared image per type, and the size set below would change it everywhere.
        image = image.copy() as? NSImage ?? image
        if item.isBrowsableFolder { image = folderImage(image, size: size, dark: Theme.isDark) }
        image.size = NSSize(width: size, height: size)
        store(image, key, size: size)
        return image
    }

    /// The type whose icon an item on this Mac shows in the Native theme, if it's its type's: not when it has a custom
    /// icon, is an app, a package, an alias or a link, or is a folder macOS draws its own way (the home folder and the
    /// folders in it, the system's, a volume, a cloud storage root). Nil: asked by its path.
    static func sharedNativeType(for item: FileItem) -> UTType? {
        guard !item.isApplication, !item.isPackage, !item.isAliasFile, !item.isSymlink, !item.hasCustomIcon else { return nil }
        guard item.isBrowsableFolder else { return item.utType.flatMap { $0.isDynamic ? nil : $0 } }
        let path = item.url.standardizedFileURL.path
        let parent = (path as NSString).deletingLastPathComponent
        if specialFolders.contains(path) || parent == "/Volumes" || parent == cloudStorage || path == "/" { return nil }
        return .folder
    }

    /// Folders with an icon of their own in Finder.
    private static let specialFolders: Set<String> = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        let mine: [FileManager.SearchPathDirectory] = [
            .desktopDirectory, .documentDirectory, .downloadsDirectory, .moviesDirectory, .musicDirectory, .picturesDirectory,
            .sharedPublicDirectory, .libraryDirectory, .applicationDirectory, .developerDirectory,
        ]
        var paths = Set(mine.flatMap { fm.urls(for: $0, in: .userDomainMask).map(\.standardizedFileURL.path) })
        paths.formUnion([home, "/Applications", "/Applications/Utilities", "/Library", "/System", "/Users", "/Users/Shared", "/Volumes"])
        paths.formUnion([home + "/Library/Mobile Documents/com~apple~CloudDocs", home + "/Sites"])
        return paths
    }()

    private static let cloudStorage = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path + "/Library/CloudStorage"

    /// The type whose icon a cloud or remote item shows in the Native theme: folders the folder, Google Docs and the
    /// like the Office document of their kind (they have no type of their own on a Mac), others their content type.
    static func nativeType(for item: FileItem) -> UTType {
        if item.isBrowsableFolder { return .folder }
        if item.isWebDocument, let kind = item.contentType?.split(separator: ".").last {
            let office = [
                "document": "org.openxmlformats.wordprocessingml.document",
                "spreadsheet": "org.openxmlformats.spreadsheetml.sheet",
                "presentation": "org.openxmlformats.presentationml.presentation",
            ]
            if let id = office[String(kind)], let t = UTType(id) { return t }
            return kind == "drawing" ? .image : .internetLocation
        }
        if let t = item.utType, !t.isDynamic { return t }
        return .data
    }

    static let nativeColourTheme = "Native, colour-coded"

    enum NativeFamily: CaseIterable {
        case pdf, word, sheet, slides, image, video, audio, archive, code, prose, unknown

        func color(dark: Bool) -> NSColor {
            let rgb: (Double, Double, Double)
            switch self {
            case .pdf: rgb = dark ? (0.81, 0.25, 0.28) : (0.73, 0.18, 0.22)
            case .word: rgb = dark ? (0.28, 0.52, 0.83) : (0.20, 0.40, 0.72)
            case .sheet: rgb = dark ? (0.26, 0.62, 0.41) : (0.18, 0.49, 0.32)
            case .slides: rgb = dark ? (0.85, 0.46, 0.23) : (0.76, 0.35, 0.16)
            case .image: rgb = dark ? (0.22, 0.61, 0.62) : (0.12, 0.48, 0.51)
            case .video: rgb = dark ? (0.60, 0.42, 0.79) : (0.49, 0.32, 0.68)
            case .audio: rgb = dark ? (0.79, 0.38, 0.57) : (0.69, 0.27, 0.46)
            case .archive: rgb = dark ? (0.68, 0.51, 0.31) : (0.56, 0.39, 0.20)
            case .code: rgb = dark ? (0.36, 0.50, 0.72) : (0.27, 0.39, 0.61)
            case .prose: rgb = dark ? (0.43, 0.55, 0.62) : (0.34, 0.45, 0.53)
            case .unknown: rgb = dark ? (0.56, 0.57, 0.59) : (0.44, 0.45, 0.47)
            }
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }

    static func nativeFamily(for item: FileItem) -> NativeFamily {
        let t = nativeType(for: item)
        let ext = item.fileExtension.lowercased()
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .spreadsheet) || ["csv", "numbers", "xlsx", "xls", "ods"].contains(ext) { return .sheet }
        if t.conforms(to: .presentation) || ["key", "pptx", "ppt", "odp"].contains(ext) { return .slides }
        if ["doc", "docx", "odt", "pages", "rtf"].contains(ext) || t.conforms(to: .compositeContent) { return .word }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .archive) || t.conforms(to: .diskImage) || ["dmg", "iso", "pkg", "7z"].contains(ext) { return .archive }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) || ["json", "yaml", "yml", "toml", "xml", "sql"].contains(ext) { return .code }
        if t.conforms(to: .text) || ["md", "markdown"].contains(ext) { return .prose }
        return .unknown
    }

    /// Rasterise at an explicit resolution, preserving the native artwork's transparent border and shadow.
    static func nativeBitmap(_ source: NSImage, pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func hasNativeColour(_ source: NSImage) -> Bool {
        let rep = nativeBitmap(source, pixels: 128), p = rep.bitmapData!
        var count = 0
        for y in 0..<128 {
            for x in 0..<128 {
                let i = y * rep.bytesPerRow + x * 4
                if p[i + 3] > 128 && Int(max(p[i], p[i + 1], p[i + 2])) - Int(min(p[i], p[i + 1], p[i + 2])) > 25 { count += 1 }
            }
        }
        return count > 128 * 128 / 200
    }

    private func nativeColourImage(_ native: NSImage, for item: FileItem, size: CGFloat) -> NSImage {
        guard !item.isBrowsableFolder, !item.isApplication, !item.isPackage, !item.isAliasFile, !item.isSymlink, !item.hasCustomIcon else {
            return native
        }
        let family = Self.nativeFamily(for: item)
        guard family != .unknown else { return native }
        let type = Self.nativeType(for: item)
        let label = item.fileExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : item.fileExtension
        let sourceKey = type.identifier as NSString
        let preserve: Bool
        if let hit = nativePreservation.object(forKey: sourceKey) {
            preserve = hit.boolValue
        } else {
            preserve = Self.hasNativeColour(NSWorkspace.shared.icon(for: type))
            nativePreservation.setObject(NSNumber(value: preserve), forKey: sourceKey)
        }
        guard !preserve else { return native }
        let key = "native-colour|\(type.identifier)|\(label)|\(size)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let typed = NSWorkspace.shared.icon(for: type)
        let looks = NativeLookImages()
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let dark = NSAppearance.currentDrawing().isDark
            let rendered = looks.image(dark: dark) {
                Self.colourNative(typed, size: size, label: label, family: family, dark: dark)
            }
            rendered.draw(in: r)
            return true
        }
        store(image, key, size: size, looks: 2)
        return image
    }

    /// Allocate and rasterise each appearance only when it is first drawn.
    private final class NativeLookImages {
        private let lock = NSLock()
        private var images: [Bool: NSImage] = [:]
        func image(dark: Bool, make: () -> NSImage) -> NSImage {
            lock.lock()
            defer { lock.unlock() }
            if let hit = images[dark] { return hit }
            let result = make()
            images[dark] = result
            return result
        }
    }

    /// Treatment C: tint only the central neutral ink; an inset band shares the page's bottom corners.
    static func colourNative(_ source: NSImage, size: CGFloat, label: String, family: NativeFamily, dark: Bool) -> NSImage {
        guard family != .unknown else { return source }
        let pixels = max(1, Int(ceil(size * 2)))
        let rep = nativeBitmap(source, pixels: pixels), p = rep.bitmapData!
        let ink = family.color(dark: dark).usingColorSpace(.deviceRGB)!
        for y in 0..<pixels {
            for x in 0..<pixels {
                let i = y * rep.bytesPerRow + x * 4
                let a = Double(p[i + 3]) / 255
                let v = Double(max(p[i], p[i + 1], p[i + 2])) / 255
                let spread = Int(max(p[i], p[i + 1], p[i + 2])) - Int(min(p[i], p[i + 1], p[i + 2]))
                if a > 0.9 && spread < 10 && v > 0.20 && v < 0.84
                    && x > pixels * 23 / 100 && x < pixels * 77 / 100 && y > pixels * 31 / 100 && y < pixels * 74 / 100
                {
                    p[i] = UInt8(ink.redComponent * a * 255)
                    p[i + 1] = UInt8(ink.greenComponent * a * 255)
                    p[i + 2] = UInt8(ink.blueComponent * a * 255)
                }
            }
        }
        let base = NSImage(size: NSSize(width: size, height: size))
        base.addRepresentation(rep)
        return NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            NSGraphicsContext.saveGraphicsState()
            // Native page edges at x .17/.82 and bottom .105; stay inside its shadow.
            let band = NSRect(x: size * 0.175, y: size * 0.112, width: size * 0.64, height: size * 0.19)
            let radius = max(0.4, size * 0.025)
            let path = NSBezierPath(roundedRect: band, xRadius: radius, yRadius: radius)
            path.appendRect(NSRect(x: band.minX, y: band.midY, width: band.width, height: band.height / 2))
            path.windingRule = .nonZero
            ink.setFill()
            path.fill()
            if size >= 32 && !label.isEmpty && label.count <= 5 {
                let text = label.uppercased() as NSString
                var fontSize = size * 0.09
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: NSColor.white, .kern: size * 0.003,
                ]
                while text.size(withAttributes: attrs).width > band.width * 0.9 {
                    fontSize *= 0.9
                    attrs[.font] = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
                    attrs[.kern] = fontSize / 30
                }
                let d = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: band.midX - d.width / 2, y: band.midY - d.height / 2), withAttributes: attrs)
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
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
