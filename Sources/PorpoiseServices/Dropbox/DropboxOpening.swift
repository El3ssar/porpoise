import Foundation
import PorpoiseCore

extension DropboxClient {
    /// UI-neutral entry to the existing Activity opening pipeline. Cache hits return before network validation.
    @MainActor public func open(_ item: DropboxItem, operations: FileOperationsController = .shared) async throws -> URL {
        let store = try await offlineCopies()
        let cached = await cachedPreview(item, store: store)
        let fileItem = item.fileItem(accountID: accountID, namespaceID: namespaceID)
        return try await CloudRemoteOpen.prepare(fileItem, cached: cached, operations: operations) { context in
            try await self.preview(item, store: store, context: context)
        }
    }
}
