import Foundation
import PorpoiseCore

/// What one location lists, and how. `DirectoryModel` keeps the state (items, rows, selection, edits, expansion,
/// search); a source only lists. Answers arrive on the main thread; a source never touches the model.
protocol LocationContentSource: AnyObject {
    var location: URL { get }
    var traits: LocationTraits { get }
    /// What can be painted at once without asking anyone (a cloud folder's saved listing); nil: wait for `load`.
    func cached(_ folder: URL) -> [FileItem]?
    /// Lists `folder` (the location, or an expanded folder in it) and the `expanded` folders below it. `deliver` gets
    /// each page, the last one `complete`, or the failure. Cancelling the returned load drops what's still to come.
    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad
    /// Reads ahead the folders the user will probably open next (hover, the visible folders after a listing).
    func prefetch(_ folders: [URL]) -> LocationLoad
}

extension LocationContentSource {
    func cached(_ folder: URL) -> [FileItem]? { nil }
    func prefetch(_ folders: [URL]) -> LocationLoad { LocationLoad() }
}

/// One answer of a source.
struct LocationListing {
    /// The listing itself; or, from a source that pages, one page of it, then the load's end (with the whole
    /// listing as the service gave it, or the failure).
    enum Part { case whole, page, end }
    var part = Part.whole
    var items: [FileItem] = []
    /// The expanded folders' listings, when the source lists them with the folder.
    var children: [URL: [FileItem]]?
    var complete = true
    var error: LocationLoadError?
    /// The folder itself is gone (only sources that can tell say so).
    var vanished: Bool?
}

/// A listing's failure in the user's words.
enum LocationLoadError: Equatable {
    case permission, privacy, unreadable(String), provider(String), smartFolder

    var message: String {
        switch self {
        case .permission: return "You don't have permission to view this folder."
        case .privacy: return "macOS protects this folder. Give Porpoise Full Disk Access in System Settings to see its contents."
        case .unreadable(let name): return "Could not open “\(name)”."
        case .provider(let text): return text
        case .smartFolder: return "This Smart Folder's search could not be read."
        }
    }
}

/// What differs between kinds of location once a listing arrives, as data instead of branches.
struct LocationTraits {
    enum Watch { case none, fileSystem, appLibrary }
    /// What tells the model to list again.
    var watch = Watch.none
    /// Changes still on their way are laid over the listing, and a complete listing retires the confirmed ones.
    var optimisticEdits = false
    /// Items no longer listed leave the selection.
    var prunesSelection = false
    /// The current item goes when it's no longer listed.
    var clearsCurrentItem = false
    /// Media folders may show as icons (Settings › General).
    var dynamicView = false
    /// Folders show their item count or size.
    var folderCounts = false
    /// The saved listing paints first and the answer glides in; a failure after painting it stays quiet.
    var paintsCache = false
}

extension ViewProperties {
    /// A result list: Details with each item's folder, by name or newest first.
    static func resultList(byName: Bool) -> ViewProperties {
        var p = ViewProperties()
        p.mode = .details
        p.foldersFirst = false
        p.sortRole = byName ? .name : .accessTime
        p.sortOrder = byName ? .ascending : .descending
        p.setRoles([.path, .accessTime], for: .details)
        return p
    }
}

/// A load in progress; cancelling it drops what it would still deliver.
final class LocationLoad {
    private var onCancel: (() -> Void)?
    init(cancel: (() -> Void)? = nil) { onCancel = cancel }
    func cancel() {
        onCancel?()
        onCancel = nil
    }
}

enum LocationContentSources {
    /// A location's built-in display style, before one is saved there.
    static func defaultStyle(for url: URL) -> ViewProperties {
        switch LocationKind.of(url) {
        case .cloud(let provider): return CloudSource.defaultStyle(url, provider.descriptor)
        case .tag, .smartFolder: return SpotlightListSource.defaultStyle
        case .recentFiles, .recentLocations: return RecentSource.defaultStyle(url)
        default: return ViewProperties.defaults(for: url)
        }
    }

    /// The source that lists `url`.
    static func source(for url: URL) -> LocationContentSource {
        switch LocationKind.of(url) {
        case .tag, .smartFolder: return SpotlightListSource(location: url)
        case .recentFiles, .recentLocations: return RecentSource(location: url)
        case .airDrop: return AirDropSource(location: url)
        case .network: return NetworkSource(location: url)
        case .archive: return ArchiveSource(location: url)
        default: break
        }
        if AppLibrary.isActive(for: url) { return AppLibrarySource(location: url) }
        if let provider = RemoteFS.provider(for: url) {
            if let cloud = provider as? CloudFileProvider { return CloudSource(location: url, provider: cloud) }
            return ProviderSource(location: url, provider: provider)
        }
        return LocalSource(location: url)
    }
}

/// AirDrop is an in-app action page, with no filesystem listing or discovery side effects.
private final class AirDropSource: LocationContentSource {
    let location: URL
    init(location: URL) { self.location = location }
    var traits: LocationTraits { LocationTraits(prunesSelection: true, clearsCurrentItem: true) }
    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        deliver(LocationListing())
        return LocationLoad()
    }
}
