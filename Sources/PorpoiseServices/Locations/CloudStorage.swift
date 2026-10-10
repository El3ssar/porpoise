import Foundation

/// Google Drive, OneDrive, Dropbox, Box… through their Mac apps.
enum CloudStorage {
    /// Folders that File Provider apps create in ~/Library/CloudStorage (e.g. "GoogleDrive-me@gmail.com").
    static func locations(in root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage"))
        -> [(title: String, url: URL, icon: String)]
    {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { n in
            guard !n.hasPrefix(".") else { return nil }
            let u = root.appendingPathComponent(n)
            let lower = n.lowercased()
            let (title, icon): (String, String) = {
                if lower.hasPrefix("googledrive") { return ("Google Drive", "folder-gdrive") }
                if lower.hasPrefix("onedrive") { return ("OneDrive", "folder-onedrive") }
                if lower.hasPrefix("dropbox") { return ("Dropbox", "folder-dropbox") }
                if lower.hasPrefix("box") { return ("Box", "folder-cloud") }
                if lower.hasPrefix("pcloud") { return ("pCloud", "folder-pcloud") }
                return (n.components(separatedBy: "-").first ?? n, "folder-cloud")
            }()
            let account = n.contains("-") ? " (" + n.components(separatedBy: "-").dropFirst().joined(separator: "-") + ")" : ""
            return (title + account, u, IconTheme.shared.has(icon) ? icon : "folder-cloud")
        }
    }
}
