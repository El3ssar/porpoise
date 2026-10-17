import Foundation
import PorpoiseCore

/// Opaque Dropbox IDs stay in locations. Display names become paths only at the API/local publication boundaries.
public final class DropboxProvider: CloudFileProvider, @unchecked Sendable {
    public let client: DropboxClient
    public let descriptor = CloudProvider.dropbox.descriptor
    public var openingOperations = FileOperationsController.shared
    private let lock = NSLock()
    private var namespaces: [String: DropboxClient] = [:]
    private var active = true
    public init(client: DropboxClient) { self.client = client }
    public func location(_ url: URL) throws -> DropboxLocation {
        guard let location = DropboxLocation(url: url), location.accountID == client.accountID else { throw DropboxError.invalidLocation }
        return location
    }
    public func scoped(_ url: URL) throws -> DropboxClient {
        let location = try location(url)
        guard let namespace = location.namespaceID, namespace != client.namespaceID else { return client }
        return lock.withLock {
            if let existing = namespaces[namespace] { return existing }
            let scoped = client.namespaceClient(namespace); namespaces[namespace] = scoped
            Task { if self.lock.withLock({ self.active }) { await scoped.changes.start() } }
            return scoped
        }
    }
    public func setActive(_ active: Bool) {
        let clients = lock.withLock {
            self.active = active; return Array(namespaces.values) + [client]
        }
        for client in clients { Task { if active { await client.changes.start() } else { await client.changes.stop() } } }
    }
    /// Stops every namespace's change feed and waits for them (before the account's folder goes).
    public func stopFeeds() async {
        let clients = lock.withLock {
            active = false; return Array(namespaces.values) + [client]
        }
        for client in clients { await client.changes.stop() }
    }
    public func checkForChanges() async throws {
        let clients = lock.withLock { Array(namespaces.values) + [client] }
        for client in clients { try await client.changes.check() }
    }
    public func item(_ file: DropboxItem, client: DropboxClient? = nil) -> FileItem {
        let client = client ?? self.client
        let url: URL
        if file.id.hasPrefix("ns:") {
            url = DropboxLocation(accountID: client.accountID, namespaceID: String(file.id.dropFirst(3))).url
        } else {
            url = DropboxLocation(accountID: client.accountID, itemID: file.id, namespaceID: client.namespaceID).url
        }
        return FileItem(
            url: url, name: file.name, isDirectory: file.isFolder, size: file.size ?? 0,
            modificationDate: file.serverModified.flatMap { FileFormat.iso8601($0) },
            contentType: file.isFolder ? "public.folder" : nil, isWritable: true)
    }
    public func metadata(_ url: URL) -> DropboxItem? {
        guard let location = try? location(url), let scoped = try? scoped(url) else { return nil }
        return scoped.metadataCache.file(location.itemID)
    }
    public func path(_ folder: URL) async throws -> String {
        let location = try location(folder)
        if location.itemID.isEmpty { return "" }
        guard !location.itemID.hasPrefix("collection:") else { throw DropboxError.invalidLocation }
        let file = try await scoped(folder).metadata(location.itemID)
        guard file.isFolder, let path = file.pathDisplay else { throw DropboxError.invalidLocation }; return path
    }
    public func cachedListing(_ folder: URL) -> [FileItem]? {
        guard let location = try? location(folder), let scoped = try? scoped(folder) else { return nil }
        return scoped.metadataCache.snapshot(location.itemID)?.files.map { item($0, client: scoped) }
    }
    public func refresh(_ folder: URL, onPage: @escaping @Sendable ([FileItem], Bool) async -> Void) async throws -> [FileItem] {
        let location = try location(folder); let scoped = try scoped(folder)
        if location.itemID == "collection:shared" {
            let files = try await scoped.sharedWithMe(); scoped.metadataCache.store(files, key: location.itemID)
            let result = files.map { item($0, client: scoped) }; await onPage(result, true); return result
        }
        if location.itemID == "collection:team" {
            let files = try await client.list(); let result = files.map { item($0) }; await onPage(result, true); return result
        }
        return try await scoped.list(location.itemID) { files, done in await onPage(files.map { self.item($0, client: scoped) }, done) }.map {
            item($0, client: scoped)
        }
    }
    public func prefetch(_ folders: [URL]) async {
        for folder in folders.prefix(4) where cachedListing(folder) == nil { if Task.isCancelled { break }; _ = try? await refresh(folder) }
    }
    public func displayName(for url: URL) -> String? {
        guard let location = try? location(url) else { return nil }
        switch location.itemID {
        case "": return descriptor.root(.myDrive).title
        case "collection:shared": return descriptor.root(.sharedWithMe).title
        case "collection:team": return descriptor.root(.sharedDrives).title
        default: return metadata(url)?.name
        }
    }
    public func rootTitle(_ url: URL) -> String { displayName(for: url) ?? descriptor.title }
    public func list(_ folder: URL) throws -> [FileItem] { try CloudAwait.run { try await self.refresh(folder) } }
    public func transferItem(_ url: URL) throws -> FileItem {
        let location = try location(url); let scoped = try scoped(url)
        return try CloudAwait.run { self.item(try await scoped.metadata(location.itemID), client: scoped) }
    }
    public func preview(_ remote: URL, thumbnail: Bool = false) async throws -> URL {
        let location = try location(remote); let scoped = try scoped(remote)
        let file: DropboxItem
        if let cached = metadata(remote) { file = cached } else { file = try await scoped.metadata(location.itemID) }
        if thumbnail { return try await scoped.thumbnail(file) }
        return try await scoped.open(file, operations: openingOperations)
    }
    public func download(_ remote: URL, into localFolder: URL) throws -> URL {
        let location = try location(remote); let scoped = try scoped(remote)
        let file = try CloudAwait.run { try await scoped.metadata(location.itemID) }
        let name = try RemoteFS.localName(file.name)
        if file.isFolder {
            return try RemoteFS.downloadStaged(name, into: localFolder) { staging in
                let target = staging.appendingPathComponent(name);
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                for child in try list(remote) { _ = try download(child.url, into: target) }
            }
        }
        let context = transferContext()
        let staging = try CloudAwait.run { try await scoped.download(file, context: context) }
        return try RemoteFS.downloadStaged(name, into: localFolder) { folder in
            try FileManager.default.copyItem(at: staging, to: folder.appendingPathComponent(name))
        }
    }
    public func upload(_ local: URL, into remoteFolder: URL) throws {
        let scoped = try scoped(remoteFolder)
        let parent = try CloudAwait.run { try await self.path(remoteFolder) }
        let context = transferContext()
        if (try? local.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let created = try CloudAwait.run { try await scoped.createFolder(name: local.lastPathComponent, parent: parent) }
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try upload(child, into: item(created, client: scoped).url)
            }
        } else {
            let path = try DropboxClient.childPath(name: local.lastPathComponent, parent: parent)
            _ = try CloudAwait.run { try await scoped.upload(local, to: path, context: context) }
        }
    }
    public func delete(_ remote: [URL]) throws {
        for url in remote {
            let scoped = try scoped(url); let id = try location(url).itemID
            _ = try CloudAwait.run { try await scoped.delete(scoped.metadata(id)) }
        }
    }
    public func makeFolder(_ remote: URL) throws { throw DropboxError.invalidLocation }
    public func rename(_ remote: URL, to newName: String) throws {
        let scoped = try scoped(remote); let id = try location(remote).itemID
        _ = try CloudAwait.run { try await scoped.rename(scoped.metadata(id), to: newName) }
    }
    public func move(_ remote: [URL], into folder: URL) throws { try relocate(remote, into: folder, move: true) }
    public func copy(_ remote: [URL], into folder: URL) throws { try relocate(remote, into: folder, move: false) }
    private func relocate(_ remote: [URL], into folder: URL, move: Bool) throws {
        let scoped = try scoped(folder); let parent = try CloudAwait.run { try await self.path(folder) }
        for url in remote {
            guard try self.scoped(url) === scoped else { throw DropboxError.invalidLocation }
            let id = try location(url).itemID
            _ = try CloudAwait.run {
                let file = try await scoped.metadata(id); let target = try DropboxClient.childPath(name: file.name, parent: parent)
                return try await move ? scoped.move(file, to: target) : scoped.copy(file, to: target)
            }
        }
    }
    func transferContext() -> CloudTransferContext {
        let control = Shell.currentTransferControl; let bytes = ByteCount()
        return .init(
            checkpoint: {
                // Paused: waits, until resumed, cancelled or interrupted (quit, sleep), as Drive's transfers do.
                while control?.isPaused() == true && control?.isCancelled() != true && control?.isInterrupted() != true {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                if control?.isInterrupted() == true { throw FileOperationError.interrupted }
                if control?.isCancelled() == true { throw FileOperationError.cancelled }
                try Task.checkCancellation()
            },
            progress: { count, _ in
                let delta = bytes.lock.withLock {
                    let delta = max(0, count - bytes.value); bytes.value = count; return delta
                }; control?.onBytes(delta)
            })
    }
    private final class ByteCount: @unchecked Sendable { let lock = NSLock(); var value: Int64 = 0 }
}
