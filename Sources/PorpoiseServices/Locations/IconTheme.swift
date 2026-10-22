import Foundation
import PorpoiseCore

/// The bundled Tela-circle icon theme's files: which icon names exist and where each one is (the app draws them).
public final class IconTheme {
    public static let shared = IconTheme()

    private let root: URL
    /// Icon file per name and size directory (small, fixed set). Read from any thread (Places loads off main).
    private var pathCache: [String: URL?] = [:]
    private let cacheLock = NSLock()

    private static let fixedSizes = [16, 22, 24]
    private static let contexts = ["actions", "places", "devices", "mimetypes", "emblems", "status"]

    private init() {
        if let env = TestEnvironment.resources.value() {
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
        guard FileName.isValid(name, for: .component) else { return nil }
        let preferences = Settings.shared.appearancePreferences
        let key = "\(preferences.iconTheme)|\(preferences.folderVariant)|\(name)|\(size)"
        if let cached = cacheLock.withLock({ pathCache[key] }) { return cached }
        let names = [name]
        var roots: [URL] = []
        if Self.installedThemes.contains(preferences.iconTheme) {
            let selected = Self.userIconsDirectory.appendingPathComponent(preferences.iconTheme)
            roots.append(selected)
            // Follow freedesktop Inherits, with cycle protection and a bounded chain.
            var visited: Set<String> = [preferences.iconTheme]
            var index = 0
            while index < roots.count, roots.count < 16 {
                let text = (try? String(contentsOf: roots[index].appendingPathComponent("index.theme"), encoding: .utf8)) ?? ""
                for line in text.components(separatedBy: .newlines) where line.hasPrefix("Inherits=") {
                    for raw in line.dropFirst(9).split(separator: ",") {
                        let parent = raw.trimmingCharacters(in: .whitespaces)
                        if Self.installedThemes.contains(parent), visited.insert(parent).inserted {
                            roots.append(Self.userIconsDirectory.appendingPathComponent(parent))
                        }
                    }
                }
                index += 1
            }
        }
        if Self.bundledThemes.contains(preferences.iconTheme) {
            roots.append(root.appendingPathComponent("themes/" + preferences.iconTheme))
        }
        roots.append(root)
        let found = roots.lazy.compactMap { root -> URL? in
            var directories: [String] = []
            let text = (try? String(contentsOf: root.appendingPathComponent("index.theme"), encoding: .utf8)) ?? ""
            for line in text.components(separatedBy: .newlines) where line.hasPrefix("Directories=") || line.hasPrefix("ScaledDirectories=") {
                directories += line.split(separator: "=", maxSplits: 1).last?.split(separator: ",").map(String.init) ?? []
            }
            var sizeDirs = [String(size), "scalable"] + Self.fixedSizes.map(String.init)
            if size <= 32, let exact = Self.fixedSizes.first(where: { $0 >= size }) { sizeDirs.insert(String(exact), at: 0) }
            let standard = sizeDirs.flatMap { dir in Self.contexts.map { "\(dir)/\($0)" } }
            // Declared freedesktop directories can use 48x48, symbolic, or arbitrary theme-specific names.
            directories = standard + directories.sorted { abs(Self.directorySize($0) - size) < abs(Self.directorySize($1) - size) }
            for name in names {
                for directory in directories where !directory.hasPrefix("/") && !directory.split(separator: "/").contains("..") {
                    for ext in ["svg", "png", "pdf"] {
                        let file = root.appendingPathComponent(directory).appendingPathComponent(name + "." + ext)
                        if FileManager.default.fileExists(atPath: file.path) { return file }
                    }
                }
            }
            return nil
        }.first
        cacheLock.withLock { pathCache[key] = found }
        return found
    }

    private static func directorySize(_ directory: String) -> Int {
        Int(directory.prefix(while: { $0.isNumber })) ?? 64
    }
    public static var userIconsDirectory: URL {
        Settings.supportFolder.appendingPathComponent("icons")
    }
    public static let bundledThemes = ["Papirus", "Breeze", "Fluent", "WhiteSur", "Colloid"]

    public static func isFolderIcon(_ name: String) -> Bool {
        name == "folder" || name.hasPrefix("folder-") || ["user-home", "user-desktop", "desktop", "user-trash", "user-trash-full"].contains(name)
    }

    public static var installedThemes: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(at: userIconsDirectory, includingPropertiesForKeys: nil)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.theme").path) }.map(\.lastPathComponent)
            .sorted()
    }

    public func has(_ name: String) -> Bool { file(name, size: 22) != nil }

    /// Whether the best file for `name` at `size` pixels is a smaller fixed-size drawing that would be blown up (Tela has
    /// `folder-apple` only as a 16 px glyph: at 96 px it is a giant Apple logo among folder tiles).
    public func isUpscaled(_ name: String, size: Int) -> Bool {
        guard let url = file(name, size: size) else { return false }
        let directory = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        guard let pixels = Int(directory.prefix(while: \.isNumber)) else { return false }
        return pixels < size
    }

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
