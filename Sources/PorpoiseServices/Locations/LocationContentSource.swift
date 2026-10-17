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
    /// Folders the user will probably open next (hover, the visible folders after a listing).
    func prefetch(_ folders: [URL])
}

extension LocationContentSource {
    func cached(_ folder: URL) -> [FileItem]? { nil }
    func prefetch(_ folders: [URL]) {}
}

/// One answer of a source.
struct LocationListing {
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
    /// The source that lists `url`.
    static func source(for url: URL) -> LocationContentSource {
        if let provider = RemoteFS.provider(for: url) { return ProviderSource(location: url, provider: provider) }
        return LocalSource(location: url)
    }
}
