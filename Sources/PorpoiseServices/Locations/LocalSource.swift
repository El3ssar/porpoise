import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// Physical identity and path, read only on listing/validation workers. An old lexical URL alone is
/// insufficient: a directory can be replaced or a symlink can point somewhere else while away.
struct LocalFolderIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let generation: UInt32
    let path: String

    static func read(_ folder: URL) -> Self? {
        guard folder.isFileURL, access(folder.path, R_OK | X_OK) == 0 else { return nil }
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat(), buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &info) == 0, fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return Self(device: info.st_dev, inode: info.st_ino, generation: info.st_gen, path: String(cString: buffer))
    }
}

/// A folder on this Mac, listed off the main thread: it may be huge or on a slow mount.
final class LocalSource: LocationContentSource {
    let location: URL
    init(location: URL) { self.location = location }
    #if PORPOISE_TEST_HOOKS
    var loadForTesting: ((URL, Set<URL>, @escaping (LocationListing) -> Void) -> LocationLoad)?
    #endif

    var traits: LocationTraits {
        let file = location.isFileURL
        return LocationTraits(
            watch: file ? .fileSystem : .none, optimisticEdits: true, prunesSelection: true, clearsCurrentItem: true, dynamicView: file,
            folderCounts: file)
    }

    func load(_ folder: URL, expanded: Set<URL>, deliver: @escaping (LocationListing) -> Void) -> LocationLoad {
        #if PORPOISE_TEST_HOOKS
        if let loadForTesting { return loadForTesting(folder, expanded, deliver) }
        #endif
        // A newer load (FSEvents during a download, the user moving on) cancels this one: it stops listing, so
        // superseded listings don't pile up on a slow mount.
        let cancellation = DiskCancellation()
        DispatchQueue.global(qos: .userInitiated).async {
            let cancelled = { cancellation.isCancelled }
            var listing = LocationListing()
            let before = LocalFolderIdentity.read(folder)
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
            let urls = listing.items.map(\.url) + kids.values.flatMap { $0.map(\.url) }
            let keys = FilePath.keys(urls, cancelled: cancelled)
            guard !cancelled() else { return }
            listing.entryKeys = Dictionary(zip(urls, keys), uniquingKeysWith: { first, _ in first })
            if listing.error == nil, let before, before == LocalFolderIdentity.read(folder) { listing.localIdentity = before }
            DispatchQueue.main.async { deliver(listing) }
        }
        return LocationLoad { cancellation.cancel() }
    }

    static func validate(_ folder: URL, identity: LocalFolderIdentity, completion: @escaping (Bool) -> Void) -> LocationLoad {
        let cancellation = DiskCancellation()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !cancellation.isCancelled else { return }
            let matches = LocalFolderIdentity.read(folder) == identity
            DispatchQueue.main.async {
                guard !cancellation.isCancelled else { return }
                completion(matches)
            }
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
