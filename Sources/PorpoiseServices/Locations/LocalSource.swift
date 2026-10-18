import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// A folder on this Mac, listed off the main thread: it may be huge or on a slow mount.
final class LocalSource: LocationContentSource {
    let location: URL
    init(location: URL) { self.location = location }

    var traits: LocationTraits {
        let file = location.isFileURL
        return LocationTraits(
            watch: file ? .fileSystem : .none, optimisticEdits: true, prunesSelection: true, clearsCurrentItem: true, dynamicView: file,
            folderCounts: file)
    }

    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        // A newer load (FSEvents during a download, the user moving on) cancels this one: it stops listing, so
        // superseded listings don't pile up on a slow mount.
        let cancellation = DiskCancellation()
        DispatchQueue.global(qos: .userInitiated).async {
            let cancelled = { cancellation.isCancelled }
            var listing = LocationListing()
            do { listing.items = try DirectoryLister.list(folder, cancelled: cancelled) } catch {
                if cancelled() { return }
                listing.error = Self.error(error, folder)
            }
            listing.vanished = listing.error != nil && folder.isFileURL && !FileManager.default.fileExists(atPath: folder.path)
            var kids: [URL: [FileItem]] = [:]
            for e in expanded {
                if cancelled() { return }
                kids[e] = (try? DirectoryLister.list(e, cancelled: cancelled)) ?? []
            }
            if cancelled() { return }
            listing.children = kids
            DispatchQueue.main.async { deliver(listing) }
        }
        return LocationLoad { cancellation.cancel() }
    }

    static func error(_ error: Error, _ folder: URL) -> LocationLoadError {
        switch FileErrorKind.classify(error, readable: access(folder.path, R_OK) == 0) {
        case .permission: return .permission
        case .privacy: return .privacy
        default: return .unreadable(folder.lastPathComponent)
        }
    }
}
