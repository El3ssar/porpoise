import Foundation
import PorpoiseCore

/// Network: the servers found nearby so far (the browser keeps looking).
final class NetworkSource: LocationContentSource {
    let location: URL
    init(location: URL) { self.location = location }

    var traits: LocationTraits { LocationTraits() }

    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        NetworkBrowser.shared.start()
        deliver(LocationListing(items: NetworkBrowser.shared.items))
        return LocationLoad()
    }
}

/// The Applications folder as an app library: every app from its roots in one grid, listed off the main thread.
final class AppLibrarySource: LocationContentSource {
    let location: URL
    init(location: URL) { self.location = location }

    var traits: LocationTraits { LocationTraits(watch: .appLibrary, prunesSelection: true) }

    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = AppLibrary.listAll()
            DispatchQueue.main.async { deliver(LocationListing(items: apps)) }
        }
        return LocationLoad()
    }
}
