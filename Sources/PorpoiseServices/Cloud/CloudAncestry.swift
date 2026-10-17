import Foundation

/// Locations that carry the item's ancestry: every path component after the account is a folder's id
/// (gdrive://account/my-drive/folder-id/item-id). A pasted link's "folder" prefix is no place to go.
public enum CloudAncestry {
    public static func fromPath(_ url: URL) -> [URL] {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.query = nil
        let parts = url.pathComponents.filter { $0 != "/" }
        var result: [URL] = []
        var path = ""
        for (i, part) in parts.dropLast().enumerated() {
            path += "/" + part
            if i == 0 && part == "folder" { continue }
            c.path = path + "/"
            if let u = c.url { result.append(u) }
        }
        return result
    }
}

// Services whose locations carry the ancestry (Google Drive).
extension CloudBackend {
    public func ancestors(of url: URL) -> [URL] { CloudAncestry.fromPath(url) }
}

extension CloudEditEntry {
    /// The folder the file is in, for Show in Folder.
    public var folder: URL { CloudAccounts.shared.ancestors(of: location).last ?? location.deletingLastPathComponent() }
}
