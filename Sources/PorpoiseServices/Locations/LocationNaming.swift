import Foundation

/// The same names and addresses in tabs, breadcrumbs, panels, palettes and the clipboard.
public enum LocationNaming {
    /// A provider's cached name, never an opaque cloud ID. This does not list or fetch an item.
    public static func name(for url: URL) -> String {
        let kind = LocationKind.of(url)
        if kind.isLocal { return url.path == "/" ? "/" : url.lastPathComponent }
        if case .cloud(let provider) = kind {
            return (RemoteFS.provider(for: url) as? any CloudFileProvider)?.displayName(for: url) ?? provider.title
        }
        if let title = kind.title { return title }
        if kind == .smartFolder { return url.deletingPathExtension().lastPathComponent }
        if url.path.isEmpty || url.path == "/" {
            return (kind.isRemote ? RemoteFS.provider(for: url)?.rootTitle(url) : nil) ?? url.host ?? url.scheme ?? ""
        }
        return kind.isRemote && url.lastPathComponent == "~" ? "Home" : url.lastPathComponent
    }

    public static func title(for url: URL) -> String { PlacesModel.shared.title(for: url) ?? name(for: url) }
    public static func connectionTitle(for url: URL) -> String {
        LocationKind.of(url).isCloud ? title(for: url) : url.host ?? address(for: url)
    }
    public static func icon(for url: URL) -> String {
        let kind = LocationKind.of(url)
        return kind.isLocal ? IconTheme.folderIconName(url) : kind.icon
    }
    public static func address(for url: URL) -> String { url.isFileURL ? url.path : RemoteFS.withoutPassword(url).absoluteString }
    public static func clipboardText(for urls: [URL]) -> String { urls.map(address(for:)).joined(separator: "\n") }

    public static func context(for url: URL) -> String {
        let kind = LocationKind.of(url)
        if kind.isLocal { return (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
        if case .cloud(let provider) = kind { return provider.title }
        return url.host.map { "\(url.scheme ?? "") · \($0)" } ?? address(for: url)
    }
}

extension URL {
    public var folderName: String { LocationNaming.name(for: self) }
}
