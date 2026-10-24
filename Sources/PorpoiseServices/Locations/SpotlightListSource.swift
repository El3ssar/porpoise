import Foundation
import PorpoiseCore

/// A tag's files, or a Finder Smart Folder's, found with Spotlight.
final class SpotlightListSource: LocationContentSource {
    let location: URL
    init(location: URL) { self.location = location }

    var traits: LocationTraits { LocationTraits() }
    static let defaultStyle = ViewProperties.resultList(byName: true)

    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        let found = deliver
        let query: MetadataListQuery?
        if LocationKind.of(folder) == .smartFolder {
            query = MetadataListQuery.smartFolder(URL(fileURLWithPath: folder.path), done: found)
            if query == nil { deliver(LocationListing(error: .smartFolder)) }
        } else {
            let tag = folder.path.hasPrefix("/") ? String(folder.path.dropFirst()) : folder.path
            query = MetadataListQuery.tagged(tag, done: found)
        }
        // The query keeps answering until the next load replaces it.
        return LocationLoad { _ = query }
    }
}
