import Foundation
import PorpoiseCore

extension DriveCloudBackend {
    public func content(for accountID: String) -> CloudContentSource? {
        guard let id = UUID(uuidString: accountID) else { return nil }
        return MainActor.assumeIsolated { store.client(for: id)?.contentSource }
    }
}
