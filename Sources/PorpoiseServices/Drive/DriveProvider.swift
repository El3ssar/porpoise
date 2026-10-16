import Foundation
import PorpoiseCore

/// Blocking compatibility adapter, called by DirectoryModel's background queue. New callers use DriveClient pages.
public final class DriveProvider: RemoteProvider, @unchecked Sendable {
    public let accountID: UUID
    public let client: DriveClient?
    private let accountName: String

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
        let location = try location(folder)
        guard let client else { throw DriveError.reconnect }
        return try Self.wait {
            let files = try await client.list(location)
            var items: [FileItem] = []
            for file in files {
                var target: DriveFile?
                if file.isShortcut {
                    // A broken/inaccessible shortcut stays visible, without pretending it can be browsed.
                    target = try? await client.resolve(file)
                }
                items.append(file.fileItem(accountID: self.accountID, shortcutTarget: target, parent: location))
            }
            return items
        }
    }

    public func listPage(_ folder: URL, pageToken: String? = nil) async throws -> (items: [FileItem], nextPageToken: String?) {
        let location = try location(folder)
        guard let client else { throw DriveError.reconnect }
        let page = try await client.listPage(location, pageToken: pageToken)
        var items: [FileItem] = []
        for file in page.files {
            try Task.checkCancellation()
            let target = file.isShortcut ? try? await client.resolve(file) : nil
            items.append(file.fileItem(accountID: accountID, shortcutTarget: target, parent: location))
        }
        return (items, page.nextPageToken)
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
