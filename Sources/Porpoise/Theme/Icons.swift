import AppKit
import UniformTypeIdentifiers
import PorpoiseCore
import PorpoiseServices

/// Loads Tela-circle-dark icons from the app bundle and recolors them the way KDE's KIconLoader does
/// (replacing the SVG "current-color-scheme" stylesheet with the active color scheme).
final class Icons {
    static let shared = Icons()

    private let root: URL
    /// Rendered icons by name, pixel size and state (and app icons by path). Bounded: continuous zoom asks for
    /// many sizes, and browsing /Applications for many app icons.
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 3000
        return c
    }()
    /// Icon file per name and size directory (small, fixed set).
    private var pathCache: [String: URL?] = [:]
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

    private static let fixedSizes = [16, 22, 24]
    private static let contexts = ["actions", "places", "devices", "mimetypes", "emblems", "status"]

    private init() {
        if let env = ProcessInfo.processInfo.environment["PORPOISE_RESOURCES"] {
            root = URL(fileURLWithPath: env).appendingPathComponent("icons")
        } else if let r = Bundle.main.resourceURL?.appendingPathComponent("icons"),
                  FileManager.default.fileExists(atPath: r.path) {
            root = r
        } else {
            // `swift run` from the project folder.
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/icons")
        }
    }

    /// Finds the best file for an icon name at a pixel size, like the freedesktop icon lookup.
    private func file(_ name: String, size: Int) -> URL? {
        // Exact fixed size first for small icons (pixel-perfect symbolic icons), then scalable, then any.
        var sizeDirs: [String] = []
        if size <= 32, let exact = Self.fixedSizes.first(where: { $0 >= size }) { sizeDirs.append("\(exact)") }
        sizeDirs.append("scalable")
        sizeDirs += Self.fixedSizes.reversed().map(String.init)
        // Sizes that search the same directories share an entry.
        let key = "\(name)@\(sizeDirs[0])"
        if let cached = pathCache[key] { return cached }
        let fm = FileManager.default
        let found = sizeDirs.lazy.flatMap { dir in Self.contexts.lazy.map { (dir, $0) } }
            .map { self.root.appendingPathComponent("\($0.0)/\($0.1)/\(name).svg") }
            .first { fm.fileExists(atPath: $0.path) }
        pathCache[key] = found
        return found
    }

    func has(_ name: String) -> Bool { file(name, size: 22) != nil }

    /// Icon image by freedesktop name. `selected` uses highlighted-text colors (like KDE's selected state).
    func image(_ name: String, size: CGFloat, selected: Bool = false) -> NSImage? {
        let px = Int(size)
        let key = "\(name)|\(px)|\(selected)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let url = file(name, size: px), let svg = try? String(contentsOf: url, encoding: .utf8),
              let data = Self.recolor(svg, stylesheet: Theme.iconStylesheet(selected: selected)).data(using: .utf8),
              let img = NSImage(data: data) else { return nil }
        img.size = NSSize(width: size, height: size)
        cache.setObject(img, forKey: key)
        return img
    }

    static func recolor(_ svg: String, stylesheet: String) -> String {
        guard let r = svg.range(of: #"<style[^>]*id="current-color-scheme"[^>]*>[\s\S]*?</style>"#,
                                options: .regularExpression),
              let open = svg[r].range(of: ">") else { return svg }
        let head = svg[r.lowerBound...open.lowerBound]
        return svg.replacingCharacters(in: r, with: head + stylesheet + "</style>")
    }

    // MARK: - File icons

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    /// Icon name for a file item (freedesktop naming, Tela has them as mimetypes/places icons).
    func iconName(for item: FileItem) -> String {
        if item.isBrowsableFolder { return Self.folderIconName(item.url) }
        if item.fileExtension == "savedSearch" { return "folder-saved-search" }
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

    static func folderIconName(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        let h = homePath
        switch p {
        case h: return "user-home"
        case h + "/Desktop": return "user-desktop"
        case h + "/Documents": return "folder-documents"
        case h + "/Downloads": return "folder-download"
        case h + "/Music": return "folder-music"
        case h + "/Pictures": return "folder-pictures"
        case h + "/Movies": return "folder-videos"
        case h + "/Public": return "folder-public"
        case h + "/.Trash": return "user-trash"
        case h + "/Library/Mobile Documents/com~apple~CloudDocs": return "folder-cloud"
        case h + "/Applications", "/Applications": return "folder-apple"
        case "/": return "drive-harddisk"
        default: break
        }
        if p.hasPrefix("/Volumes/"), url.deletingLastPathComponent().path == "/Volumes" { return "drive-removable-media" }
        return "folder"
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
        // Finder aliases look like their original (the view adds the link emblem).
        if item.isAliasFile, let t = aliasTarget(of: item), !t.isAliasFile { return image(for: t, size: size, selected: selected) }
        if item.isApplication || (item.isPackage && !item.isBrowsableFolder && item.fileExtension.lowercased() == "app") {
            let key = "app|\(item.url.path)|\(Int(size))" as NSString
            if let img = cache.object(forKey: key) { return img }
            let img = NSWorkspace.shared.icon(forFile: item.url.path)
            img.size = NSSize(width: size, height: size)
            cache.setObject(img, forKey: key)
            return img
        }
        let name = iconName(for: item)
        if name == "unknown" {
            // A type the theme has no icon for: the icon macOS declares for it (as Finder shows), else a generic file.
            if let t = item.utType, !t.isDynamic {
                let key = "type|\(t.identifier)|\(Int(size))"
                if let img = cache.object(forKey: key as NSString) { return img }
                let img = NSWorkspace.shared.icon(for: t)
                img.size = NSSize(width: size, height: size)
                cache.setObject(img, forKey: key as NSString)
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
