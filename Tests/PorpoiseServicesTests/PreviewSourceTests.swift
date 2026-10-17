import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

/// Previews of items not on this Mac come from one place: a server's file as a temporary copy (removed by whoever
/// made the preview), a cloud service's own preview, and when to ask again after a failure.
@Suite(.serialized, .isolatedSettings) struct PreviewSourceTests {
    @Test func aServerFileComesAsATemporaryCopy() async throws {
        let root = URL(string: "sftp://preview-\(UUID().uuidString.prefix(8).lowercased()).invalid/")!
        let server = MemoryServer(root: root)
        server.add("photo.jpg", size: 4)
        RemoteFS.use(server, for: root)
        defer { RemoteFS.use(nil, for: root) }
        let local = try await PreviewSource.localFile(for: root.appendingPathComponent("photo.jpg"), thumbnail: true)
        let cleanup = try #require(local.cleanup)
        defer { try? FileManager.default.removeItem(at: cleanup) }
        #expect(local.file.lastPathComponent == "photo.jpg" && local.file.deletingLastPathComponent().path == cleanup.path)
        #expect((try FileManager.default.attributesOfItem(atPath: local.file.path)[.size] as? Int) == 4)
        await #expect(throws: (any Error).self) { try await PreviewSource.localFile(for: root.appendingPathComponent("gone.jpg"), thumbnail: true) }
        #expect(!PreviewSource.isProgressive(root) && PreviewSource.retryDelay(for: root) == nil)
        await #expect(throws: CocoaError.self) {
            try await PreviewSource.progressive(root.appendingPathComponent("photo.jpg"), context: CloudTransferContext()) { _ in }
        }
    }

    @Test func cloudPreviewsAreAskedForAgainSoon() async {
        let drive = URL(string: "gdrive://\(UUID().uuidString)/my-drive")!
        #expect(PreviewSource.retryDelay(for: drive) == 5 && PreviewSource.isProgressive(drive))
        await #expect(throws: (any Error).self) { try await PreviewSource.localFile(for: URL(string: "recent:/files")!, thumbnail: true) }
    }
}
