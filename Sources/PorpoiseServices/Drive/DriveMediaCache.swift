import Foundation

public typealias DriveMediaCache = CloudRenditionCache
extension CloudRenditionCache {
    public init(accountID: UUID, directory: URL? = nil, byteLimit: Int = 200 << 20) {
        self.init(
            directory: directory
                ?? DriveMetadataCache.root.appendingPathComponent(accountID.uuidString).appendingPathComponent("Previews", isDirectory: true),
            byteLimit: byteLimit, invalidResponse: { DriveError.invalidResponse })
    }
}
