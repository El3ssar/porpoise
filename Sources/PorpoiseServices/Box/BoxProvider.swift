import Foundation
import PorpoiseCore

/// Opaque item IDs stay in locations. Display names become Box names only at the API boundary.
public final class BoxProvider: CloudFileProvider, @unchecked Sendable {
    public let client: BoxClient
    public let descriptor = CloudProvider.box.descriptor
    public var openingOperations = FileOperationsController.shared
    public init(client: BoxClient) { self.client = client }
    public func location(_ url: URL) throws -> BoxLocation {
        guard let location = BoxLocation(url: url), location.accountID == client.accountID else { throw BoxError.invalidLocation }
        return location
    }
    public func setActive(_ active: Bool) {
        Task { if active { await client.changes.start() } else { await client.changes.stop() } }
    }
    public func stopFeeds() async { await client.changes.stop() }
    public func checkForChanges() async throws { try await client.changes.check() }
    public func item(_ file: BoxItem) -> FileItem {
        FileItem(
            url: BoxLocation(accountID: client.accountID, itemID: file.location.itemID, kind: file.kind).url, name: file.name,
            isDirectory: file.isFolder, size: file.size ?? 0, modificationDate: file.modified.flatMap { FileFormat.iso8601($0) },
            contentType: file.isFolder ? "public.folder" : nil, isWritable: true)
    }
    /// One item, however it's named: the type in the URL doesn't change which item it is.
    public func sameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = try? location(lhs), let b = try? location(rhs) else { return lhs == rhs }
        return a.apiID == b.apiID
    }
    /// The item read for `url`, from what's cached.
    public func metadata(_ url: URL) -> BoxItem? {
        guard let location = try? location(url) else { return nil }
        return client.metadataCache.file(location.apiID)
    }
    /// The item `url` names, read now.
    func fetch(_ url: URL) async throws -> BoxItem {
        let location = try location(url)
        return try await client.metadata(location.apiID, kind: location.kind)
    }
    /// The folder ID an operation names ("0" is the root).
    public func folderID(_ folder: URL) throws -> String {
        let location = try location(folder)
        guard location.kind == nil || location.kind == .folder else { throw BoxError.invalidLocation }
        return location.apiID
    }
    public func cachedListing(_ folder: URL) -> [FileItem]? {
        guard let location = try? location(folder) else { return nil }
        return client.metadataCache.snapshot(location.apiID)?.files.map(item)
    }
    public func refresh(_ folder: URL, onPage: @escaping @Sendable ([FileItem], Bool) async -> Void) async throws -> [FileItem] {
        let id = try folderID(folder)
        return try await client.list(id) { files, done in await onPage(files.map(self.item), done) }.map(item)
    }
    public func prefetch(_ folders: [URL]) async {
        for folder in folders.prefix(4) where cachedListing(folder) == nil { if Task.isCancelled { break }; _ = try? await refresh(folder) }
    }
    public func displayName(for url: URL) -> String? {
        guard let location = try? location(url) else { return nil }
        return location.itemID.isEmpty ? descriptor.root(.myDrive).title : metadata(url)?.name
    }
    public func rootTitle(_ url: URL) -> String { displayName(for: url) ?? descriptor.title }
    public func list(_ folder: URL) throws -> [FileItem] { try CloudAwait.run { try await self.refresh(folder) } }
    public func transferItem(_ url: URL) throws -> FileItem { try CloudAwait.run { self.item(try await self.fetch(url)) } }
    public func preview(_ remote: URL, thumbnail: Bool = false) async throws -> URL {
        let file: BoxItem
        if let cached = metadata(remote) { file = cached } else { file = try await fetch(remote) }
        if thumbnail { return try await client.thumbnail(file) }
        return try await client.open(file, operations: openingOperations)
    }
    public func download(_ remote: URL, into localFolder: URL) throws -> URL {
        let file = try CloudAwait.run { try await self.fetch(remote) }
        let name = try RemoteFS.localName(file.name)
        if file.isFolder {
            return try RemoteFS.downloadStaged(name, into: localFolder) { staging in
                let target = staging.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                for child in try list(remote) { _ = try download(child.url, into: target) }
            }
        }
        let context = transferContext()
        let staging = try CloudAwait.run { try await self.client.download(file, context: context) }
        return try RemoteFS.downloadStaged(name, into: localFolder) { folder in
            try FileManager.default.copyItem(at: staging, to: folder.appendingPathComponent(name))
        }
    }
    public func upload(_ local: URL, into remoteFolder: URL) throws {
        let parent = try folderID(remoteFolder)
        let context = transferContext()
        if (try? local.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let created = try CloudAwait.run { try await self.client.createFolder(name: local.lastPathComponent, parentID: parent) }
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try upload(child, into: item(created).url)
            }
        } else {
            _ = try CloudAwait.run { try await self.client.upload(local, to: parent, named: local.lastPathComponent, context: context) }
        }
    }
    public func delete(_ remote: [URL]) throws {
        for url in remote { _ = try CloudAwait.run { try await self.client.delete(self.fetch(url)) } }
    }
    public func makeFolder(_ remote: URL) throws { throw BoxError.invalidLocation }
    public func rename(_ remote: URL, to newName: String) throws {
        _ = try CloudAwait.run { try await self.client.rename(self.fetch(remote), to: newName) }
    }
    public func move(_ remote: [URL], into folder: URL) throws { try relocate(remote, into: folder, move: true) }
    public func copy(_ remote: [URL], into folder: URL) throws { try relocate(remote, into: folder, move: false) }
    private func relocate(_ remote: [URL], into folder: URL, move: Bool) throws {
        let parent = try folderID(folder)
        for url in remote {
            _ = try CloudAwait.run {
                let file = try await self.fetch(url)
                return try await move ? self.client.move(file, to: parent) : self.client.copy(file, to: parent)
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

extension BoxProvider {
    public func playback(_ url: URL) async throws -> CloudPlayback {
        let file = try await fetch(url)
        let store = try await client.offlineCopies()
        if let cached = await client.cachedPreview(file, store: store) { return CloudPlayback(url: cached) }
        let stream = try client.streamingPreview(file, contentType: item(file).utType?.preferredMIMEType ?? "application/octet-stream")
        return CloudPlayback(url: stream.url, stream: stream)
    }
    public func progressivePreview(
        _ remote: URL, context: CloudTransferContext, onPreview: @escaping @MainActor (URL) async throws -> Void
    ) async throws -> URL {
        let file = try await fetch(remote)
        let store = try await client.offlineCopies()
        if let cached = await client.cachedPreview(file, store: store) { try await onPreview(cached); return cached }
        if let thumbnail = try? await client.thumbnail(file) { try Task.checkCancellation(); try await onPreview(thumbnail) }
        let full = try await client.preview(file, store: store, context: context); try await onPreview(full); return full
    }
}
