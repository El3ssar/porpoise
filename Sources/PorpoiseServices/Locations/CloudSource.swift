import Foundation
import PorpoiseCore

/// A cloud folder: its saved listing paints at once, then the service's answer arrives page by page.
final class CloudSource: LocationContentSource {
    let location: URL
    let provider: CloudFileProvider
    init(location: URL, provider: CloudFileProvider) {
        self.location = location
        self.provider = provider
    }

    var traits: LocationTraits { LocationTraits(optimisticEdits: true, prunesSelection: true, paintsCache: true) }

    func cached(_ folder: URL) -> [FileItem]? { provider.cachedListing(folder) }

    /// Delivers each page as it comes, then the end: the whole listing as the service gave it, or the failure.
    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        let provider = provider
        let task = Task { @MainActor in
            do {
                let items = try await provider.refresh(folder) { listed, complete in
                    await MainActor.run { deliver(LocationListing(part: .page, items: listed, complete: complete)) }
                }
                try Task.checkCancellation()
                deliver(LocationListing(part: .end, items: items))
            } catch is CancellationError {
                return
            } catch {
                deliver(LocationListing(part: .end, error: .provider(error.localizedDescription)))
            }
        }
        return LocationLoad { task.cancel() }
    }

    func prefetch(_ folders: [URL]) -> LocationLoad {
        let provider = provider
        let task = Task(priority: .utility) { await provider.prefetch(folders) }
        return LocationLoad { task.cancel() }
    }
}
