import Foundation
import PorpoiseCore

/// Blocking compatibility adapter, called by DirectoryModel's background queue. New callers use DriveClient pages.
public final class DriveProvider: RemoteProvider, @unchecked Sendable {
    public let accountID: UUID
    public let client: DriveClient?
    private let accountName: String
    private struct Listing {
        let files: [(DriveFile, DriveFile?)]
        let parent: URL
        let items: [FileItem]
    }
    private let cacheLock = NSLock()
    private var listings: [DriveLocation.Collection: Listing] = [:]
    private var cacheOrder: [DriveLocation.Collection] = []
    private var generation = 0

    /// Synchronous: navigation and disclosure paint without waiting for the network.
    public func cachedListing(_ folder: URL) -> [FileItem]? {
        guard let location = try? location(folder) else { return nil }
        return cacheLock.withLock {
            guard let listing = listings[location.collection] else { return nil }
            if listing.parent == folder { return listing.items }
            return listing.files.map { $0.0.fileItem(accountID: accountID, shortcutTarget: $0.1, parent: location) }
        }
    }

    /// M2 mutations can invalidate one folder; reconnect/disconnect invalidate the whole account.
    public func invalidate(folder: URL? = nil) {
        cacheLock.withLock {
            generation += 1
            if let folder, let location = try? location(folder) {
                listings[location.collection] = nil
                cacheOrder.removeAll { $0 == location.collection }
            } else {
                listings.removeAll(); cacheOrder.removeAll()
            }
        }
    }

    private func resolved(_ files: [DriveFile], client: DriveClient) async throws -> [(DriveFile, DriveFile?)] {
        // At most eight metadata requests, preserving the server's order and broken shortcuts.
        try await withThrowingTaskGroup(of: (Int, DriveFile?).self) { group in
            var targets = [DriveFile?](repeating: nil, count: files.count)
            var next = 0
            func submit(_ index: Int) {
                group.addTask {
                    try Task.checkCancellation()
                    let target = files[index].isShortcut ? try? await client.resolve(files[index]) : nil
                    try Task.checkCancellation()
                    return (index, target)
                }
            }
            while next < min(8, files.count) { submit(next); next += 1 }
            while let (index, target) = try await group.next() {
                targets[index] = target
                if next < files.count { submit(next); next += 1 }
            }
            return files.indices.map { (files[$0], targets[$0]) }
        }
    }

    /// Delivers the first page immediately; only complete listings become reusable snapshots.
    @discardableResult public func refresh(
        _ folder: URL, onPage: @escaping @Sendable ([FileItem], Bool) async -> Void = { _, _ in }
    ) async throws -> [FileItem] {
        let location = try location(folder)
        guard let client else { throw DriveError.reconnect }
        let epoch = cacheLock.withLock { generation }
        var files: [(DriveFile, DriveFile?)] = []
        var token: String?
        var seen: Set<String> = []
        repeat {
            let page = try await client.listPage(location, pageToken: token)
            files += try await resolved(page.files, client: client)
            try Task.checkCancellation()
            token = page.nextPageToken
            if let token, !seen.insert(token).inserted { throw DriveError.invalidResponse }
            let items = files.map { $0.0.fileItem(accountID: accountID, shortcutTarget: $0.1, parent: location) }
            guard cacheLock.withLock({ generation == epoch }) else { throw CancellationError() }
            await onPage(items, token == nil)
        } while token != nil
        let items = files.map { $0.0.fileItem(accountID: accountID, shortcutTarget: $0.1, parent: location) }
        cacheLock.withLock {
            guard generation == epoch else { return }
            listings[location.collection] = Listing(files: files, parent: folder, items: items)
            cacheOrder.removeAll { $0 == location.collection }
            cacheOrder.append(location.collection)
            while cacheOrder.count > 128 { listings[cacheOrder.removeFirst()] = nil }
        }
        return items
    }

    /// Low-priority callers warm a capped screenful, with four concurrent folders at most.
    public func prefetch(_ folders: [URL]) async {
        let wanted = Array(folders.filter { cachedListing($0) == nil }.prefix(8))
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func submit(_ url: URL) { group.addTask { _ = try? await self.refresh(url) } }
            while next < min(4, wanted.count), !Task.isCancelled { submit(wanted[next]); next += 1 }
            while await group.next() != nil {
                if next < wanted.count, !Task.isCancelled { submit(wanted[next]); next += 1 }
            }
        }
    }

    public init(accountID: UUID, client: DriveClient?, accountName: String = "Google Drive") {
        self.accountID = accountID; self.client = client; self.accountName = accountName
    }

    private func location(_ url: URL) throws -> DriveLocation {
        guard let location = DriveLocation(url: url), location.accountID == accountID else { throw DriveError.invalidLocation }
        return location
    }

    public func metadata(for url: URL) -> DriveFile? { client?.cachedFile(for: url) }
    public func displayName(for url: URL) -> String? {
        guard let location = DriveLocation(url: url) else { return nil }
        if case .folder = location.collection { return metadata(for: url)?.name }
        return location.title
    }
    public func rootTitle(_ url: URL) -> String { displayName(for: url) ?? accountName }

    public func list(_ folder: URL) throws -> [FileItem] {
        try Self.wait { try await self.refresh(folder) }
    }

    public func listPage(_ folder: URL, pageToken: String? = nil) async throws -> (items: [FileItem], nextPageToken: String?) {
        let location = try location(folder)
        guard let client else { throw DriveError.reconnect }
        let page = try await client.listPage(location, pageToken: pageToken)
        let files = try await resolved(page.files, client: client)
        return (files.map { $0.0.fileItem(accountID: accountID, shortcutTarget: $0.1, parent: location) }, page.nextPageToken)
    }

    public func preview(_ remote: URL, thumbnail: Bool = false) async throws -> URL {
        let location = try location(remote)
        guard let client else { throw DriveError.reconnect }
        guard case .folder(let id, _) = location.collection else { throw DriveError.invalidLocation }
        let file: DriveFile
        if let cached = metadata(for: remote) { file = cached } else { file = try await client.file(id, resourceKey: location.resourceKey) }
        if thumbnail { return try await client.thumbnail(file) }
        return try await client.preview(file)
    }

    public func download(_ remote: URL, into localFolder: URL) throws -> URL {
        let location = try location(remote)
        guard let client else { throw DriveError.reconnect }
        guard case .folder(let id, _) = location.collection else { throw DriveError.invalidLocation }
        let preset = DriveExportPreset(rawValue: Settings.store.string(forKey: "googleDriveExportPreset") ?? "") ?? .office
        let result = try Self.wait {
            try await client.download(client.file(id, resourceKey: location.resourceKey), preset: preset)
        }
        return try RemoteFS.downloadStaged(result.name, into: localFolder) { staging in
            try result.data.write(to: staging.appendingPathComponent(result.name), options: .withoutOverwriting)
        }
    }

    public func upload(_ local: URL, into remoteFolder: URL) throws { throw DriveError.readOnly }
    public func delete(_ remote: [URL]) throws { throw DriveError.readOnly }
    public func makeFolder(_ remote: URL) throws { throw DriveError.readOnly }
    public func removeEmptyFolder(_ remote: URL) throws { throw DriveError.readOnly }
    public func rename(_ remote: URL, to newName: String) throws { throw DriveError.readOnly }
    public func move(_ remote: [URL], into folder: URL) throws { throw DriveError.readOnly }
    public func copy(_ remote: [URL], into folder: URL) throws { throw DriveError.readOnly }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }
    private static func wait<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.value = .success(try await work()) } catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.value!.get()
    }
}
