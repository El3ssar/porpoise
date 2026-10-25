import Foundation
import PorpoiseCore

extension DriveContentSource: CloudMetadataOwningContentSource {
    func setMetadataOwner(_ name: String, owner: CloudMetadataRetention.Owner?, complete: Bool) {
        client?.metadataCache.storage.setRetentionOwner(name, owner.map { .init(owner: $0, complete: complete) })
    }
}

/// Drive's metadata/change feed and journaled streaming engine behind the neutral content capability.
public final class DriveContentSource: CloudContentSource, @unchecked Sendable {
    private weak var client: DriveClient?
    private let lock = NSLock()
    private var rootAliases: Set<String> = ["root"]
    private var callback: (@Sendable (CloudChangeBatch) -> Void)?
    public let accountID: String
    public let providerTitle = "Google Drive"
    public let offlineDirectory: URL?
    public var onChanges: (@Sendable (CloudChangeBatch) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    public var isOffline: Bool { client?.isOffline ?? true }
    var preset: DriveExportPreset {
        DriveExportPreset(rawValue: Settings.store.string(forKey: CloudAccounts.exportPresetKey) ?? "office") ?? .office
    }
    public init(client: DriveClient, directory: URL? = nil) {
        self.client = client; self.accountID = client.accountID.uuidString.lowercased(); self.offlineDirectory = directory
    }
    public func ref(for url: URL) -> CloudItemRef? {
        guard let location = DriveLocation(url: url), location.accountID.uuidString.lowercased() == accountID else { return nil }
        switch location.collection {
        case .myDrive: return .init(account: accountID, item: "root")
        case .folder(let id, _): return .init(account: accountID, item: id)
        case .sharedWithMe, .sharedDrives: return nil
        }
    }
    public func url(for item: CloudRemoteItem) -> URL {
        DriveLocation(accountID: UUID(uuidString: accountID)!, collection: item.ref.item == "root" ? .myDrive : .folder(item.ref.item)).url
    }
    public func remoteItem(_ file: DriveFile) -> CloudRemoteItem {
        let format = file.isGoogleDocument ? preset.format(for: file.mimeType) : nil
        var aliases = lock.withLock { rootAliases }
        if let root = client?.metadataCache.file("root")?.id { aliases.insert(root) }
        return CloudRemoteItem(
            ref: .init(account: accountID, item: file.id), name: file.name + (format.map { "." + $0.fileExtension } ?? ""),
            parents: (file.parents ?? []).map { aliases.contains($0) ? "root" : $0 }, isFolder: file.isFolder,
            size: file.isGoogleDocument ? nil : file.size.flatMap(Int64.init),
            revision: file.headRevisionId ?? file.version, checksum: file.isGoogleDocument ? nil : file.md5Checksum.map(CloudChecksum.md5),
            export: format?.fileExtension,
            canDownload: file.isFolder ? file.operations.canBrowse : file.operations.canDownload || file.operations.canExport)
    }
    public func cachedItem(_ ref: CloudItemRef) -> CloudRemoteItem? {
        guard ref.account == accountID else { return nil }
        if ref.item == "root" { return CloudRemoteItem(ref: ref, name: "My Drive", isFolder: true) }
        return client?.metadataCache.file(ref.item).map(remoteItem)
    }
    public func item(_ ref: CloudItemRef) async throws -> CloudRemoteItem {
        guard ref.account == accountID, let client else { throw CloudContentError.unsupported }
        if ref.item == "root", let root = cachedItem(ref) { return root }
        do { return remoteItem(try await client.file(ref.item)) } catch DriveError.http(404) { throw CloudContentError.notFound } catch DriveError
            .notFound
        { throw CloudContentError.notFound }
    }
    public func children(_ folder: CloudItemRef) async throws -> [CloudRemoteItem] {
        guard folder.account == accountID, let client else { throw CloudContentError.unsupported }
        let files = try await client.list(
            DriveLocation(
                accountID: client.accountID,
                collection: folder.item == "root" ? .myDrive : .folder(folder.item)))
        if folder.item == "root" { lock.withLock { rootAliases.formUnion(files.flatMap { $0.parents ?? [] }) } }
        return files.map(remoteItem)
    }
    public func discardPartial(at partial: URL) async throws {
        let sidecar = CloudOperationSidecar(
            partial: partial, account: accountID, legacy: partial.deletingLastPathComponent().appendingPathComponent(".operation"))
        guard let operation = try sidecar.existing(), let client else { return }
        if let record = try client.mutationJournal.load(operation) {
            guard record.accountID == client.accountID, record.kind == "download" else { throw DriveMutationError.sourceChanged }
            if record.phase == .done {
                let staging = client.mutationJournal.partial(operation)
                if FileManager.default.fileExists(atPath: staging.path) {
                    guard record.destinationURL == staging else { throw DriveMutationError.sourceChanged }
                    do { try CloudStagedDownload.removeOwned(staging, fingerprint: record.fingerprint) } catch CloudTransferError.sourceChanged {
                        throw DriveMutationError.sourceChanged
                    }
                }
            } else {
                try await client.cancelTransfer(operation)
            }
        }
        try? sidecar.remove()
    }
    public func holdsCopy(_ ref: CloudItemRef) async -> Bool {
        guard let client else { return false }
        return await client.edits.holdsCopy(ref.item)
    }
    public func download(
        _ item: CloudRemoteItem, to partial: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        try await download(item, to: partial, checkpoint: { try Task.checkCancellation() }, progress: progress)
    }
    public func download(
        _ item: CloudRemoteItem, to partial: URL,
        checkpoint: @escaping @Sendable () async throws -> Void,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        guard let client, item.ref.account == accountID else { throw CloudContentError.unsupported }
        let fresh: DriveFile
        if let cached = client.metadataCache.file(item.ref.item) { fresh = cached } else { fresh = try await client.file(item.ref.item) }
        guard remoteItem(fresh).revision == item.revision else { throw CloudContentError.changed }
        let sidecar = CloudOperationSidecar(
            partial: partial, account: accountID, legacy: partial.deletingLastPathComponent().appendingPathComponent(".operation"), item: item)
        let fm = FileManager.default
        if try await CloudStagedDownload.reuseVerified(item, partial: partial, refresh: { self.remoteItem(try await client.file(fresh.id)) }) {
            if let operation = try sidecar.existing() { try CloudStagedDownload.discard(operation, journal: client.mutationJournal) }
            try? sidecar.remove(); progress(item.size ?? 0, item.size); return
        }
        let operation = try sidecar.operation()
        do {
            let staged = try await client.downloadToStaging(
                fresh, preset: preset, operationID: operation,
                context: .init(checkpoint: checkpoint, progress: { bytes, total in progress(bytes, total) }))
            guard remoteItem(staged.file).revision == item.revision else {
                try? fm.removeItem(at: staged.url)
                throw CloudContentError.changed
            }
            if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
            // The staging engine has already fsynced and authenticated these bytes.
            do { try fm.moveItem(at: staged.url, to: partial) } catch { try cloudClone(staged.url, to: partial); try fm.removeItem(at: staged.url) }
            try CloudStagedDownload.discard(operation, journal: client.mutationJournal)
            try? sidecar.remove()
        } catch {
            if (error as? DriveMutationError) == .sourceChanged || (error as? CloudContentError) == .changed {
                try? sidecar.remove(); try? await client.cancelTransfer(operation)
                throw CloudContentError.changed
            }
            throw error
        }
    }
}

extension DriveClient {
    public var contentSource: DriveContentSource {
        lock.withLock {
            if let offlineSource { return offlineSource }
            let directory =
                offlineDirectory
                ?? (baseURL.host == "127.0.0.1"
                    ? FileManager.default.temporaryDirectory
                        .appendingPathComponent("porpoise-drive-offline/" + accountID.uuidString) : nil)
            let source = DriveContentSource(client: self, directory: directory)
            offlineSource = source; return source
        }
    }
    public func offlineCopies() async throws -> CloudOfflineStore {
        let source = contentSource
        return try await MainActor.run { try CloudOffline.shared.store(for: source) }
    }
    func emitContentChanges(_ batch: CloudChangeBatch) {
        let source = lock.withLock { offlineSource }
        source?.onChanges?(batch)
    }
}
