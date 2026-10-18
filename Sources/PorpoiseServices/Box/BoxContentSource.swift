import Foundation
import PorpoiseCore

public final class BoxContentSource: CloudContentSource, @unchecked Sendable {
    private weak var client: BoxClient?
    private let lock = NSLock()
    private var callback: (@Sendable (CloudChangeBatch) -> Void)?
    private let uuid: UUID
    public let accountID: String
    public let providerTitle = "Box"
    public let offlineDirectory: URL?
    public var isOffline: Bool { client?.isOffline ?? true }
    public var onChanges: (@Sendable (CloudChangeBatch) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    public init(client: BoxClient) {
        self.client = client; uuid = client.accountID
        accountID = "box:" + client.accountID.uuidString.lowercased()
        offlineDirectory = client.metadataCache.directory.deletingLastPathComponent().appendingPathComponent("Offline")
    }
    public func ref(for url: URL) -> CloudItemRef? {
        guard let client, let location = BoxLocation(url: url), location.accountID == client.accountID else {
            return nil
        }
        return .init(account: accountID, item: location.itemID)
    }
    public func url(for item: CloudRemoteItem) -> URL {
        BoxLocation(accountID: uuid, itemID: item.ref.item, kind: item.isFolder ? .folder : client?.kind(of: item.ref.item) ?? .file).url
    }
    public func remoteItem(_ item: BoxItem) -> CloudRemoteItem {
        let parent = item.parentID.map { $0 == BoxItem.rootID ? "" : $0 } ?? ""
        return CloudRemoteItem(
            ref: .init(account: accountID, item: item.isRoot ? "" : item.id), name: item.name, parents: item.isRoot ? [] : [parent],
            isFolder: item.isFolder || item.isRoot, size: item.size, revision: item.revision,
            checksum: item.sha1.map(CloudChecksum.sha1), canDownload: item.canDownload)
    }
    public func cachedItem(_ ref: CloudItemRef) -> CloudRemoteItem? {
        guard ref.account == accountID else { return nil }
        if ref.item.isEmpty { return CloudRemoteItem(ref: ref, name: "Box", isFolder: true) }
        return client?.metadataCache.file(ref.item).map(remoteItem)
    }
    public func item(_ ref: CloudItemRef) async throws -> CloudRemoteItem {
        guard ref.account == accountID, let client else { throw CloudContentError.unsupported }
        if ref.item.isEmpty, let root = cachedItem(ref) { return root }
        do { return remoteItem(try await client.metadata(ref.item)) } catch BoxError.notFound { throw CloudContentError.notFound }
    }
    public func children(_ folder: CloudItemRef) async throws -> [CloudRemoteItem] {
        guard folder.account == accountID, let client else { throw CloudContentError.unsupported }
        return try await client.list(folder.item.isEmpty ? BoxItem.rootID : folder.item).map(remoteItem)
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
        let fresh = try await client.metadata(item.ref.item, kind: .file)
        guard fresh.revision == item.revision else { throw CloudContentError.changed }
        let sidecar = CloudOperationSidecar(
            partial: partial, account: accountID, legacy: partial.appendingPathExtension("box-operation"), item: item)
        if try await CloudStagedDownload.reuseVerified(item, partial: partial, refresh: { self.remoteItem(try await client.metadata(fresh.id)) }) {
            try sidecar.remove(); progress(item.size ?? 0, item.size); return
        }
        let operation = try sidecar.operation()
        let staging = try await client.download(fresh, operationID: operation, context: .init(checkpoint: checkpoint, progress: { progress($0, $1) }))
        try await checkpoint()
        let fm = FileManager.default
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        // Moved, not copied: a verified .part left in the journal's Downloads kept every offline copy's bytes twice.
        do { try fm.moveItem(at: staging, to: partial) } catch { try cloudClone(staging, to: partial); try fm.removeItem(at: staging) }
        try sidecar.remove()
    }
    public func discardPartial(at partial: URL) async throws {
        let sidecar = CloudOperationSidecar(partial: partial, account: accountID, legacy: partial.appendingPathExtension("box-operation"))
        guard let id = try sidecar.existing(), let client else { return }
        try client.journal.claim(id); defer { client.journal.release(id) }
        if var record = try client.journal.load(id) {
            let owned = client.journal.partial(id)
            guard record.kind == "download", record.localURL == owned else { throw BoxError.sourceChanged }
            do { try CloudStagedDownload.removeOwned(owned, fingerprint: record.fingerprint) } catch CloudTransferError.sourceChanged {
                throw BoxError.sourceChanged
            }
            record.phase = "cancelled"; try client.journal.save(record)
        }
        try sidecar.remove()
    }
}

extension BoxClient {
    public func offlineCopies() async throws -> CloudOfflineStore {
        let source = contentSource
        return try await MainActor.run { try CloudOffline.shared.store(for: source) }
    }
    public func cachedPreview(_ item: BoxItem, store: CloudOfflineStore) async -> URL? {
        try? await store.localCopy(contentSource.remoteItem(item).ref, revision: item.revision)
    }
    public func preview(_ item: BoxItem, store: CloudOfflineStore, context: CloudTransferContext = .init()) async throws -> URL {
        try await store.fetch(
            contentSource.remoteItem(item), checkpoint: context.checkpoint, progress: { bytes, total in context.progress(bytes, total ?? bytes) })
    }
    /// UI-neutral entry to the existing Activity opening pipeline. Cache hits return before network validation.
    @MainActor public func open(_ item: BoxItem, operations: FileOperationsController = .shared) async throws -> URL {
        let store = try await offlineCopies()
        let cached = await cachedPreview(item, store: store)
        return try await CloudRemoteOpen.prepare(item.fileItem(accountID: accountID), cached: cached, operations: operations) {
            context in try await self.preview(item, store: store, context: context)
        }
    }
    /// The item a shared link points to, when this account can open it as itself; nil when it can't (or the link is
    /// gone). The link is only read: an item reachable only through the link (Box then wants the link with every
    /// request) isn't offered. https://developer.box.com/reference/get-shared-items/
    public func sharedLink(_ link: URL) async throws -> BoxItem? {
        do {
            let shared: BoxItem = try await get(
                api("shared_items", query: [.init(name: "fields", value: Self.fields)]), headers: ["BoxApi": "shared_link=" + link.absoluteString])
            return try await metadata(shared.id, kind: shared.kind)
        } catch BoxError.notFound { return nil } catch BoxError.api(403, _) { return nil }
    }
}
