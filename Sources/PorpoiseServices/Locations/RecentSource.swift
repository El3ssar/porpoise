import Foundation
import PorpoiseCore

/// Recent Files (Spotlight's last-used dates) and Recent Locations (the folders visited).
final class RecentSource: LocationContentSource {
    let location: URL
    init(location: URL) { self.location = location }

    var traits: LocationTraits { LocationTraits() }

    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        if LocationKind.of(folder) == .recentLocations {
            deliver(LocationListing(items: RecentLocations.shared.urls.compactMap { FileItem.load($0) }))
            return LocationLoad()
        }
        let query = RecentFilesQuery { deliver(LocationListing(items: $0)) }
        // The query keeps answering until the next load replaces it.
        return LocationLoad { _ = query }
    }
}
