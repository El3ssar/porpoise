import Foundation
import PorpoiseCore

/// Opaque item and drive IDs stay in locations. Display names become Graph names only at the API boundary.
public final class OneDriveProvider: CloudFileProvider, @unchecked Sendable {
    public let client: OneDriveClient
    public let descriptor = CloudProvider.oneDrive.descriptor
    public var openingOperations = FileOperationsController.shared
    private let lock = NSLock()
    private var drives: [String: OneDriveClient] = [:]
    private var active = true
    public init(client: OneDriveClient) { self.client = client }
    public func location(_ url: URL) throws -> OneDriveLocation {
        guard let location = OneDriveLocation(url: url), location.accountID == client.accountID else { throw OneDriveError.invalidLocation }
        return location
    }
    /// The client of the drive `url` is in: the account's own, or a shared item's owner's.
    public func scoped(_ url: URL) throws -> OneDriveClient { try drive(location(url).driveID) }
    func drive(_ driveID: String?) -> OneDriveClient {
        guard let driveID, driveID != client.driveID else { return client }
        return lock.withLock {
            if let existing = drives[driveID] { return existing }
            let scoped = client.driveClient(driveID); drives[driveID] = scoped
            return scoped
        }
    }
    public func setActive(_ active: Bool) {
        // Only the account's own drive has a feed: others' drives are read when shown (their delta isn't ours to follow).
        lock.withLock { self.active = active }
        Task { if active { await client.changes.start() } else { await client.changes.stop() } }
    }
    public func stopFeeds() async {
        lock.withLock { active = false }
        await client.changes.stop()
    }
    public func checkForChanges() async throws { try await client.changes.check() }
    public func item(_ file: OneDriveItem, client: OneDriveClient? = nil) -> FileItem {
        let client = client ?? self.client
        return FileItem(
            url: OneDriveLocation(accountID: client.accountID, itemID: file.isRoot ? "" : file.id, driveID: file.driveID ?? client.driveID).url,
            name: file.name, isDirectory: file.isFolder || file.isRoot, size: file.size ?? 0,
            modificationDate: file.modified.flatMap { FileFormat.iso8601($0) },
            contentType: file.isFolder ? "public.folder" : nil, isWritable: true)
    }
    /// One item, however it's named: no drive is the account's own, and the root's real ID is the root.
    public func sameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = try? location(lhs), let b = try? location(rhs) else { return lhs == rhs }
        func normal(_ l: OneDriveLocation) -> (String, String) {
            let scoped = drive(l.driveID)
            return (scoped.driveID, l.itemID == scoped.rootID ? "" : l.itemID)
        }
        return normal(a) == normal(b)
    }
    public func metadata(_ url: URL) -> OneDriveItem? {
        guard let location = try? location(url), let scoped = try? scoped(url) else { return nil }
        return scoped.metadataCache.file(location.itemID)
    }
    /// The folder ID an operation names ("" is the drive's root); the shared collection is not a folder.
    public func folderID(_ folder: URL) throws -> String {
        let location = try location(folder)
        guard !location.itemID.hasPrefix("collection:") else { throw OneDriveError.invalidLocation }
        return location.itemID
    }
    public func cachedListing(_ folder: URL) -> [FileItem]? {
        guard let location = try? location(folder), let scoped = try? scoped(folder) else { return nil }
        return scoped.metadataCache.snapshot(location.itemID)?.files.map { item($0, client: scoped) }
    }
    public func refresh(_ folder: URL, onPage: @escaping @Sendable ([FileItem], Bool) async -> Void) async throws -> [FileItem] {
        let location = try location(folder); let scoped = try scoped(folder)
        if location.itemID == "collection:shared" {
            let files = try await scoped.sharedWithMe()
            for (driveID, shared) in Dictionary(grouping: files, by: \.driveID) { drive(driveID).metadataCache.remember(shared) }
            let result = files.map { item($0, client: scoped) }; await onPage(result, true); return result
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
        case "" where location.driveID == nil || location.driveID == client.driveID: return descriptor.root(.myDrive).title
        case "collection:shared": return descriptor.root(.sharedWithMe).title
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
        let file: OneDriveItem
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
                let target = staging.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                for child in try list(remote) { _ = try download(child.url, into: target) }
            }
        }
        let context = transferContext()
        return try CloudAwait.run {
            try await CloudStagedDownload.consume(
                journal: scoped.journal,
                download: {
                    try await scoped.download(file, operationID: $0, context: context)
                }
            ) { staging in
                try RemoteFS.downloadStaged(name, into: localFolder) { folder in
                    try FileManager.default.copyItem(at: staging, to: folder.appendingPathComponent(name))
                }
            }
        }
    }
    public func upload(_ local: URL, into remoteFolder: URL) throws {
        let scoped = try scoped(remoteFolder), parent = try folderID(remoteFolder)
        let context = transferContext()
        if (try? local.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let created = try CloudAwait.run { try await scoped.createFolder(name: local.lastPathComponent, parentID: parent) }
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try upload(child, into: item(created, client: scoped).url)
            }
        } else {
            _ = try CloudAwait.run { try await scoped.upload(local, to: parent, named: local.lastPathComponent, context: context) }
        }
    }
    public func delete(_ remote: [URL]) throws {
        for url in remote {
            let scoped = try scoped(url); let id = try location(url).itemID
            _ = try CloudAwait.run { try await scoped.delete(scoped.metadata(id)) }
        }
    }
    public func makeFolder(_ remote: URL) throws { throw OneDriveError.invalidLocation }
    public func rename(_ remote: URL, to newName: String) throws {
        let scoped = try scoped(remote); let id = try location(remote).itemID
        _ = try CloudAwait.run { try await scoped.rename(scoped.metadata(id), to: newName) }
    }
    public func move(_ remote: [URL], into folder: URL) throws { try relocate(remote, into: folder, move: true) }
    public func copy(_ remote: [URL], into folder: URL) throws { try relocate(remote, into: folder, move: false) }
    private func relocate(_ remote: [URL], into folder: URL, move: Bool) throws {
        let scoped = try scoped(folder), parent = try folderID(folder)
        for url in remote {
            guard try self.scoped(url) === scoped else { throw OneDriveError.invalidLocation }
            let id = try location(url).itemID
            _ = try CloudAwait.run {
                let file = try await scoped.metadata(id)
                if parent.isEmpty, scoped.rootID == nil { _ = try await scoped.metadata("") }
                return try await move ? scoped.move(file, to: parent) : scoped.copy(file, to: parent)
            }
        }
    }
    func transferContext() -> CloudTransferContext { Shell.transferContext() }
}
