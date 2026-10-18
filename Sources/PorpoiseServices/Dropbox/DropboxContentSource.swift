import Foundation
import PorpoiseCore

public final class DropboxContentSource: CloudContentSource, @unchecked Sendable {
    private weak var client: DropboxClient?
    private let lock = NSLock()
    private var callback: (@Sendable (CloudChangeBatch) -> Void)?
    private let uuid: UUID
    private let namespaceID: String?
    public let accountID: String
    public let providerTitle = "Dropbox"
    public let offlineDirectory: URL?
    public var isOffline: Bool { client?.isOffline ?? true }
    public var onChanges: (@Sendable (CloudChangeBatch) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    public init(client: DropboxClient) {
        self.client = client; uuid = client.accountID; namespaceID = client.namespaceID;
        accountID = "dropbox:" + client.accountID.uuidString.lowercased() + ":" + (client.namespaceID ?? "home")
        offlineDirectory = client.metadataCache.directory.deletingLastPathComponent().appendingPathComponent("Offline")
    }
    public func ref(for url: URL) -> CloudItemRef? {
        guard let client, let location = DropboxLocation(url: url), location.accountID == client.accountID, location.namespaceID == namespaceID else {
            return nil
        }
        return .init(account: accountID, item: location.itemID)
    }
    public func url(for item: CloudRemoteItem) -> URL {
        DropboxLocation(accountID: uuid, itemID: item.ref.item, namespaceID: namespaceID).url
    }
    public func remoteItem(_ item: DropboxItem) -> CloudRemoteItem {
        let parent = item.parentPath
        let parentID = client?.folderIDs[parent] ?? (parent.isEmpty ? "" : parent)
        return CloudRemoteItem(
            ref: .init(account: accountID, item: item.id), name: item.name, parents: [parentID],
            isFolder: item.isFolder, size: item.size, revision: item.rev,
            checksum: item.contentHash.map(CloudChecksum.dropbox), canDownload: item.isDownloadable != false)
    }
    public func cachedItem(_ ref: CloudItemRef) -> CloudRemoteItem? {
        guard ref.account == accountID else { return nil }
        if ref.item.isEmpty { return CloudRemoteItem(ref: ref, name: "Dropbox", isFolder: true) }
        return client?.metadataCache.file(ref.item).map(remoteItem)
    }
    public func item(_ ref: CloudItemRef) async throws -> CloudRemoteItem {
        guard ref.account == accountID, let client else { throw CloudContentError.unsupported }
        if ref.item.isEmpty, let root = cachedItem(ref) { return root }
        do { return remoteItem(try await client.metadata(ref.item)) } catch DropboxError.notFound { throw CloudContentError.notFound }
    }
    public func children(_ folder: CloudItemRef) async throws -> [CloudRemoteItem] {
        guard folder.account == accountID, let client else { throw CloudContentError.unsupported }
        return try await client.list(folder.item).map(remoteItem)
    }
    public func holdsCopy(_ ref: CloudItemRef) async -> Bool {
        guard let client, ref.account == accountID else { return false }; return await client.edits.holdsCopy(ref.item)
    }
    public func download(_ item: CloudRemoteItem, to partial: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try await download(item, to: partial, checkpoint: { try Task.checkCancellation() }, progress: progress)
    }
    public func download(
        _ item: CloudRemoteItem, to partial: URL, checkpoint: @escaping @Sendable () async throws -> Void,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        guard let client, item.ref.account == accountID else { throw CloudContentError.unsupported }
        let fresh = try await client.metadata(item.ref.item)
        guard fresh.rev == item.revision else { throw CloudContentError.changed }
        let sidecar = CloudOperationSidecar(
            partial: partial, account: accountID, legacy: partial.appendingPathExtension("dropbox-operation"), item: item)
        if try await CloudStagedDownload.reuseVerified(item, partial: partial, refresh: { self.remoteItem(try await client.metadata(fresh.id)) }) {
            try sidecar.remove(); progress(item.size ?? 0, item.size); return
        }
        let operation = try sidecar.operation()
        let staging = try await client.download(fresh, operationID: operation, context: .init(checkpoint: checkpoint, progress: { progress($0, $1) }))
        try await checkpoint()
        if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
        try cloudClone(staging, to: partial)
        try sidecar.remove()
    }
    public func discardPartial(at partial: URL) async throws {
        let sidecar = CloudOperationSidecar(partial: partial, account: accountID, legacy: partial.appendingPathExtension("dropbox-operation"))
        guard let id = try sidecar.existing(), let client else { return }
        try client.journal.claim(id); defer { client.journal.release(id) }
        if var record = try client.journal.load(id) {
            let owned = client.journal.partial(id)
            guard record.kind == "download", record.localURL == owned else { throw DropboxError.sourceChanged }
            do { try CloudStagedDownload.removeOwned(owned, fingerprint: record.fingerprint) } catch CloudTransferError.sourceChanged {
                throw DropboxError.sourceChanged
            }
            record.phase = "cancelled"; try client.journal.save(record)
        }
        try sidecar.remove()
    }
}

extension DropboxClient {
    public func offlineCopies() async throws -> CloudOfflineStore {
        let source = contentSource
        return try await MainActor.run { try CloudOffline.shared.store(for: source) }
    }
    public func cachedPreview(_ item: DropboxItem, store: CloudOfflineStore) async -> URL? {
        try? await store.localCopy(contentSource.remoteItem(item).ref, revision: item.rev)
    }
    public func preview(_ item: DropboxItem, store: CloudOfflineStore, context: CloudTransferContext = .init()) async throws -> URL {
        try await store.fetch(
            contentSource.remoteItem(item), checkpoint: context.checkpoint, progress: { bytes, total in context.progress(bytes, total ?? bytes) })
    }
}
