import Foundation
import PorpoiseCore

/// Google Drive kept fresh: when a folder was last read, Drive's own search, and a look for changes when asked.
extension DriveCloudBackend {
    func client(for url: URL) -> DriveClient? {
        guard let location = DriveLocation(url: url) else { return nil }
        return MainActor.assumeIsolated { store.client(for: location.accountID) }
    }

    public func savedAt(for folder: URL) -> Date? {
        guard let location = DriveLocation(url: folder) else { return nil }
        return client(for: folder)?.metadataCache.snapshot(location)?.savedAt
    }

    public func search(
        _ text: String, in folder: URL, everywhere: Bool, contents: Bool, pageToken: String?,
        done: @escaping (Result<CloudSearchPage, Error>) -> Void
    ) -> () -> Void {
        guard let location = DriveLocation(url: folder), let client = client(for: folder) else {
            done(.failure(DriveError.invalidLocation))
            return {}
        }
        // Everywhere: all the account can see (My Drive and what's shared with it). A folder: its own items.
        let scope = everywhere || location.collection == .sharedDrives ? DriveLocation(accountID: location.accountID) : location
        let parent: DriveLocation? = everywhere ? nil : location
        let task = Task { @MainActor in
            do {
                let page = try await client.search(text, in: scope, fullText: contents, pageToken: pageToken)
                try Task.checkCancellation()
                let items = page.files.map { $0.fileItem(accountID: location.accountID, parent: parent) }
                done(.success(CloudSearchPage(items: items, nextPageToken: page.nextPageToken)))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                done(.failure(error))
            }
        }
        return { task.cancel() }
    }

    /// Asks Drive for changes now (the app came to the front, or the user reloaded): what changed shows by itself.
    public func checkForChanges(_ id: String?) {
        let clients = MainActor.assumeIsolated {
            store.accounts.filter { id == nil || Self.key($0.id) == id }.compactMap { store.client(for: $0.id) }
        }
        for client in clients { Task { try? await client.pollChanges() } }
    }
}
