import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// Recent Files (Spotlight's last-used dates) and Recent Locations (the folders visited).
final class RecentSource: LocationContentSource {
    let location: URL
    init(location: URL) { self.location = location }

    var traits: LocationTraits { LocationTraits() }
    /// Recent Files newest first; Recent Locations by name.
    static func defaultStyle(_ url: URL) -> ViewProperties { .resultList(byName: url.path == "/locations") }

    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        if LocationKind.of(folder) == .recentLocations {
            deliver(LocationListing(items: RecentLocations.shared.urls.compactMap { FileItem.load($0) }))
            return LocationLoad()
        }
        let query = RecentFilesQuery(done: deliver)
        // The query keeps answering until the next load replaces it.
        return LocationLoad { _ = query }
    }
}
