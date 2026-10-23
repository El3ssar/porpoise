import Foundation
import PorpoiseCore

/// Blocking compatibility adapter, called by DirectoryModel's background queue. New callers use DriveClient pages.
public final class DriveProvider: RemoteProvider, @unchecked Sendable {
    public let accountID: UUID
    public var openingOperations: FileOperationsController = .shared
    public let client: DriveClient?
    private let accountName: String
    private let accountEmail: String?
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
            guard let listing = listings[location.collection] else {
                return client?.metadataCache.snapshot(location)?.files.map { file in
                    file.fileItem(
                        accountID: accountID, shortcutTarget: file.shortcutDetails.flatMap { client?.metadataCache.file($0.targetId) },
                        parent: location)
                }
            }
            if listing.parent == folder { return listing.items }
            return listing.files.map { $0.0.fileItem(accountID: accountID, shortcutTarget: $0.1, parent: location) }
        }
    }

    /// M2 mutations can invalidate one folder; reconnect/disconnect invalidate the whole account.
    public func invalidate(folder: URL? = nil, preserveDisk: Bool = false) {
        cacheLock.withLock {
            generation += 1
            if !preserveDisk { client?.metadataCache.invalidate(folder.flatMap(DriveLocation.init(url:))) }
            if let folder, let location = try? location(folder) {
                func matches(_ collection: DriveLocation.Collection) -> Bool {
                    if case .folder(let id, _) = collection, case .folder(let other, _) = location.collection { return id == other }
                    return collection == location.collection
                }
                for key in listings.keys.filter(matches) { listings[key] = nil }
                cacheOrder.removeAll(where: matches)
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
        // What a change made here while this lists (a rename) is newer than the listing: it isn't undone.
        let since = client.metadataCache.generation
        if case .myDrive = location.collection { _ = try? await client.file("root") }
        let epoch = cacheLock.withLock { generation }
        var files: [(DriveFile, DriveFile?)] = []
        var token: String?
        var seen: Set<String> = []
        repeat {
            let page: DrivePage
            do { page = try await client.listPage(location, pageToken: token) } catch {
                if client.isOffline, let cached = cachedListing(folder) {
                    await onPage(cached, true)
                    return cached
                }
                throw error
            }
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
            client.metadataCache.store(files.map { $0.0 }, at: location, since: since)
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

    public init(accountID: UUID, client: DriveClient?, accountName: String = "Google Drive", accountEmail: String? = nil) {
        self.accountID = accountID; self.client = client; self.accountName = accountName; self.accountEmail = accountEmail
    }

    func location(_ url: URL) throws -> DriveLocation {
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

    public func preview(_ remote: URL, thumbnail: Bool = false) async throws -> URL {
        let location = try location(remote)
        guard let client else { throw DriveError.reconnect }
        guard case .folder(let id, _) = location.collection else { throw DriveError.invalidLocation }
        if !thumbnail, metadata(for: remote) == nil {
            let item = FileItem(url: remote, name: displayName(for: remote) ?? "cloud file", isDirectory: false)
            return try await CloudRemoteOpen.prepare(item, operations: openingOperations) { context in
                let file = try await client.file(id, resourceKey: location.resourceKey)
                return try await client.preview(file, context: context)
            }
        }
        let file: DriveFile
        if let cached = metadata(for: remote) { file = cached } else { file = try await client.file(id, resourceKey: location.resourceKey) }
        if thumbnail { return try await client.thumbnail(file) }
        let cached = try await client.cachedPreview(file)
        if cached != nil {
            // Validate quietly; this open never waits on the network.
            Task { _ = try? await client.file(file.id, resourceKey: file.resourceKey) }
        }
        return try await CloudRemoteOpen.prepare(file.fileItem(accountID: accountID), cached: cached, operations: openingOperations) { context in
            try await client.preview(file, context: context)
        }
    }

    public func download(_ remote: URL, into localFolder: URL) throws -> URL {
        try download(remote, into: localFolder, operationID: UUID())
    }

    func download(_ remote: URL, into localFolder: URL, operationID: UUID) throws -> URL {
        let location = try location(remote)
        guard let client else { throw DriveError.reconnect }
        guard case .folder(let id, _) = location.collection else { throw DriveError.invalidLocation }
        let preset = DriveExportPreset(rawValue: Settings.store.string(forKey: "googleDriveExportPreset") ?? "") ?? .office
        let context = transferContext()
        let known = metadata(for: remote)
        let result = try Self.wait {
            let file: DriveFile
            if let known { file = known } else { file = try await client.file(id, resourceKey: location.resourceKey) }
            return try await client.downloadToStaging(file, preset: preset, operationID: operationID, context: context)
        }
        return try RemoteFS.downloadStaged(result.name, into: localFolder) { staging in
            // The private recovery partial is 0600. A published download gets normal creation permissions,
            // honoring the process umask without changing that process-global setting.
            let target = staging.appendingPathComponent(result.name)
            let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let input = try FileHandle(forReadingFrom: result.url)
            defer { try? input.close(); try? output.close() }
            while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
                try Shell.currentTransferControl?.check()
                try output.write(contentsOf: data)
            }
            try output.synchronize()
        }
    }

    public func capabilities(for url: URL) -> DriveItemCapabilities? {
        guard let location = try? location(url) else { return nil }
        switch location.collection {
        case .sharedWithMe, .sharedDrives: return DriveFile(id: "virtual", name: "", mimeType: "application/vnd.google-apps.folder").operations
        case .myDrive: return client?.cachedFile(for: DriveLocation(accountID: accountID, collection: .folder("root")).url)?.operations
        case .folder:
            guard let file = metadata(for: url) else { return nil }
            var capabilities = file.operations
            if let email = accountEmail?.lowercased() {
                capabilities.role =
                    file.owners?.contains { $0.emailAddress?.lowercased() == email } == true
                    ? "owner"
                    : file.permissions?.first { $0.emailAddress?.lowercased() == email }?.role
            }
            return capabilities
        }
    }

    public func parentID(_ folder: URL) throws -> String {
        switch try location(folder).collection {
        case .myDrive: return "root"
        case .folder(let id, _): return id
        default: throw DriveError.permissionDenied
        }
    }

    private func itemID(_ url: URL) throws -> String {
        guard case .folder(let id, _) = try location(url).collection else { throw DriveError.invalidLocation }
        return id
    }

    public func createFolder(named name: String, in folder: URL) async throws -> FileItem {
        guard let client else { throw DriveError.reconnect }
        let result = try await client.createFolder(name: name, parentID: parentID(folder))
        return result.fileItem(accountID: accountID, parent: try location(folder))
    }

    public func rename(_ url: URL, to name: String) async throws -> FileItem {
        guard let client else { throw DriveError.reconnect }
        let result = try await client.rename(itemID(url), to: name)
        return result.fileItem(accountID: accountID, parent: DriveLocation(url: url.deletingLastPathComponent()))
    }

    public struct TrashResult: Sendable {
        public var trashed: [URL] = []
        public var failures: [URL: String] = [:]
    }
    public func trash(_ urls: [URL]) async -> TrashResult {
        var result = TrashResult()
        for url in urls {
            do {
                guard let client else { throw DriveError.reconnect }
                _ = try await client.setTrashed(itemID(url), trashed: true)
                result.trashed.append(url)
            } catch { result.failures[url] = error.localizedDescription }
        }
        return result
    }
    public func untrash(_ urls: [URL]) async throws {
        guard let client else { throw DriveError.reconnect }
        for url in urls { _ = try await client.setTrashed(itemID(url), trashed: false) }
    }

    public func upload(_ local: URL, into remoteFolder: URL) throws {
        var ancestors: Set<String> = []
        try upload(local, into: remoteFolder, ancestors: &ancestors)
    }

    private func upload(_ local: URL, into remoteFolder: URL, ancestors: inout Set<String>) throws {
        guard let client else { throw DriveError.reconnect }
        let context = transferContext()
        try Self.wait { try await context.checkpoint() }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let path = local.resolvingSymlinksInPath().standardizedFileURL.path
            // Match other folder-upload adapters: follow directory links, but never recurse into an ancestor.
            guard ancestors.insert(path).inserted else { return }
            defer { ancestors.remove(path) }
            let folder = try Self.wait { try await self.createFolder(named: local.lastPathComponent, in: remoteFolder) }
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try upload(child, into: folder.url, ancestors: &ancestors)
            }
            return
        }
        let parent = try parentID(remoteFolder)
        _ = try Self.wait { try await client.upload(local, parentID: parent, context: context) }
    }
    public func delete(_ remote: [URL]) throws {
        guard let client else { throw DriveError.reconnect }
        for url in remote {
            let id = try itemID(url)
            _ = try Self.wait { try await client.setTrashed(id, trashed: true) }
        }
    }
    public func makeFolder(_ remote: URL) throws {
        _ = try Self.wait { try await self.createFolder(named: remote.lastPathComponent, in: remote.deletingLastPathComponent()) }
    }
    public func removeEmptyFolder(_ remote: URL) throws {
        guard try list(remote).isEmpty else { throw DriveMutationError.conflict }
        try delete([remote])
    }
    public func rename(_ remote: URL, to newName: String) throws {
        let _: FileItem = try Self.wait { try await self.rename(remote, to: newName) }
    }
    public func move(_ remote: [URL], into folder: URL) throws {
        guard let client else { throw DriveError.reconnect }
        let parent = try parentID(folder)
        for url in remote {
            let id = try itemID(url)
            _ = try Self.wait { try await client.move(id, to: parent) }
        }
    }
    public func copy(_ remote: [URL], into folder: URL) throws {
        guard let client else { throw DriveError.reconnect }
        let parent = try parentID(folder)
        for url in remote {
            let id = try itemID(url)
            _ = try Self.wait { try await client.copy(id, to: parent) }
        }
    }

    func transferContext() -> DriveTransferContext { Shell.transferContext() }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }
    /// Runs `work` and blocks the calling thread until it's done (the providers' synchronous API, for file jobs on
    /// threads of their own). Never on a thread of the cooperative pool: the work may need a pool thread (a token
    /// refresh, a change feed), and with the few the pool has blocked so (CI's 3-core runner), nothing runs again.
    static func wait<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        assert(
            !String(cString: __dispatch_queue_get_label(nil)).hasSuffix(".cooperative"),
            "A blocking provider call on a cooperative thread: call it from a thread of its own (tests: offThePool).")
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
