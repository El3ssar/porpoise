import Foundation
import PorpoiseCore

/// The Applications folder shown as an app library (Launchpad style): every app from /Applications, Apple's own
/// apps in /System/Applications and ~/Applications in one grid, ignoring the view settings of other folders.
public enum AppLibrary {
    public static let location = URL(fileURLWithPath: "/Applications")

    /// Folders whose apps are shown; the first one wins when two hold an app of the same name.
    public static var roots: [URL] {
        [location, URL(fileURLWithPath: "/System/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    public static func isActive(for url: URL) -> Bool {
        Settings.shared.appLibraryView && url.isFileURL && url.standardizedFileURL.path == location.path
    }

    /// Apps in the roots and one folder level below them (Utilities, a vendor's folder…).
    public static func listAll() -> [FileItem] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [FileItem] = []
        func add(_ url: URL) {
            guard seen.insert(url.lastPathComponent.lowercased()).inserted, let it = FileItem.load(url) else { return }
            out.append(it)
        }
        for root in roots {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])) ?? []
            for e in entries {
                if e.pathExtension == "app" { add(e); continue }
                guard (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let inner = (try? fm.contentsOfDirectory(at: e, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                inner.filter { $0.pathExtension == "app" }.forEach(add)
            }
        }
        return out
    }

    /// The name people know the app by ("Safari", not "Safari.app").
    public static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
    }

    /// Part of macOS (System volume): can't be moved to the Trash.
    public static func isBuiltIn(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix("/System/") }

    /// View properties of the library: names A to Z, nothing hidden (the grid draws itself).
    public static func props() -> ViewProperties {
        var p = ViewProperties()
        p.mode = .icons
        p.sortRole = .name
        p.sortOrder = .ascending
        p.foldersFirst = false
        return p
    }
}
