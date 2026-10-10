import Foundation

/// The bundled Tela-circle icon theme's files: which icon names exist and where each one is (the app draws them).
public final class IconTheme {
    public static let shared = IconTheme()

    private let root: URL
    /// Icon file per name and size directory (small, fixed set).
    private var pathCache: [String: URL?] = [:]

    private static let fixedSizes = [16, 22, 24]
    private static let contexts = ["actions", "places", "devices", "mimetypes", "emblems", "status"]

    private init() {
        if let env = ProcessInfo.processInfo.environment["PORPOISE_RESOURCES"] {
            root = URL(fileURLWithPath: env).appendingPathComponent("icons")
        } else if let r = Bundle.main.resourceURL?.appendingPathComponent("icons"),
            FileManager.default.fileExists(atPath: r.path)
        {
            root = r
        } else {
            // `swift run` from the project folder.
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/icons")
        }
    }

    /// Finds the best file for an icon name at a pixel size, like the freedesktop icon lookup.
    public func file(_ name: String, size: Int) -> URL? {
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

    public func has(_ name: String) -> Bool { file(name, size: 22) != nil }

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    public static func folderIconName(_ url: URL) -> String {
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
}
