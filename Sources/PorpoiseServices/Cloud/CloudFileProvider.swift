import Foundation
import PorpoiseCore

/// Browser/open capabilities, independent of the remote API and its URL syntax.
public protocol CloudFileProvider: RemoteProvider, Sendable {
    var descriptor: CloudProviderDescriptor { get }
    func cachedListing(_ folder: URL) -> [FileItem]?
    func refresh(_ folder: URL, onPage: @escaping @Sendable ([FileItem], Bool) async -> Void) async throws -> [FileItem]
    func prefetch(_ folders: [URL]) async
    func displayName(for url: URL) -> String?
    func preview(_ remote: URL, thumbnail: Bool) async throws -> URL
    func progressivePreview(_ remote: URL, context: CloudTransferContext, onPreview: @escaping @MainActor (URL) async throws -> Void) async throws
        -> URL
    func playback(_ url: URL) async throws -> CloudPlayback
    func transferItem(_ url: URL) throws -> FileItem
}
extension CloudFileProvider {
    public func refresh(_ folder: URL) async throws -> [FileItem] { try await refresh(folder, onPage: { _, _ in }) }
    public func preview(_ remote: URL) async throws -> URL { try await preview(remote, thumbnail: false) }
    public func progressivePreview(_ remote: URL, context: CloudTransferContext, onPreview: @escaping @MainActor (URL) async throws -> Void)
        async throws -> URL
    {
        let local = try await preview(remote); try await onPreview(local); return local
    }
}
extension DriveProvider: CloudFileProvider {
    public var descriptor: CloudProviderDescriptor { CloudProvider.googleDrive.descriptor }
    public func progressivePreview(_ remote: URL, context: CloudTransferContext, onPreview: @escaping @MainActor (URL) async throws -> Void)
        async throws -> URL
    {
        guard let client, let location = DriveLocation(url: remote), case .folder(let id, _) = location.collection else {
            throw DriveError.invalidLocation
        }
        let file = try await client.file(id, resourceKey: location.resourceKey)
        return try await client.progressivePreview(file, context: context, show: onPreview)
    }
    public func transferItem(_ url: URL) throws -> FileItem {
        guard let client, let location = DriveLocation(url: url), case .folder(let id, _) = location.collection else {
            throw DriveError.invalidLocation
        }
        return try Self.wait {
            try await client.file(id).fileItem(accountID: self.accountID, parent: DriveLocation(url: url.deletingLastPathComponent()))
        }
    }
}

/// Blocking compatibility is used only by DirectoryModel/FileOperations worker queues.
public enum CloudAwait {
    private final class Box<T>: @unchecked Sendable { var result: Result<T, Error>? }
    public static func run<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0); let box = Box<T>()
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }; semaphore.signal()
        }
        semaphore.wait(); return try box.result!.get()
    }
}
