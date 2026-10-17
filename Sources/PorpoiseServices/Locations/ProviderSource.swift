import Foundation
import PorpoiseCore

/// A folder on a server or a device (SFTP, FTP, adb), listed through its provider off the main thread.
final class ProviderSource: LocationContentSource {
    let location: URL
    let provider: RemoteProvider
    init(location: URL, provider: RemoteProvider) {
        self.location = location
        self.provider = provider
    }

    var traits: LocationTraits { LocationTraits(optimisticEdits: true, prunesSelection: true) }

    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        let provider = provider
        DispatchQueue.global(qos: .userInitiated).async {
            var listing = LocationListing()
            do { listing.items = try provider.list(folder) } catch { listing.error = .provider(error.localizedDescription) }
            var kids: [URL: [FileItem]] = [:]
            for e in expanded { kids[e] = (try? provider.list(e)) ?? [] }
            listing.children = kids
            DispatchQueue.main.async { deliver(listing) }
        }
        return LocationLoad()
    }
}
