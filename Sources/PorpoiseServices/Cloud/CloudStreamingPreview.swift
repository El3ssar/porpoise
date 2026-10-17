import Foundation

/// Selection-owned loopback stream. Upstream authentication and immutable-revision reads remain in the provider.
public final class CloudStreamingPreview {
    private let server: LocalFileServer
    public let url: URL
    public init(size: Int64, contentType: String, read: @escaping @Sendable (Range<Int64>) async throws -> Data) throws {
        guard size > 0, !contentType.contains("\r"), !contentType.contains("\n") else { throw CloudTransferError.invalidResponse }
        let server = LocalFileServer()
        self.server = server
        guard let url = server.start(source: .init(size: size, contentType: contentType, read: read)) else {
            throw CloudTransferError.invalidResponse
        }
        self.url = url
    }
    public func stop() { server.stop() }
    deinit { server.stop() }
}
