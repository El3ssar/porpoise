import Foundation
import PorpoiseCore
import PorpoiseTestSupport
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

    /// A copy cancelled while another is downloading is never fetched (thumbnails scrolled away before their turn).
    @Test(.timeLimit(.minutes(2))) func aCancelledCopyWaitingItsTurnIsNeverFetched() async throws {
        let root = URL(string: "sftp://preview-\(UUID().uuidString.prefix(8).lowercased()).invalid/")!
        let server = GatedPreviewServer()
        RemoteFS.use(server, for: root)
        defer { RemoteFS.use(nil, for: root) }
        let first = Task { try await PreviewSource.localFile(for: root.appendingPathComponent("a.jpg"), thumbnail: true) }
        #expect(await poll { server.names == ["a.jpg"] })
        let second = Task { try await PreviewSource.localFile(for: root.appendingPathComponent("b.jpg"), thumbnail: true) }
        second.cancel()
        server.gate.signal()
        let local = try await first.value
        try? FileManager.default.removeItem(at: try #require(local.cleanup))
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(server.names == ["a.jpg"])
    }

    @Test func cloudPreviewsAreAskedForAgainSoon() async {
        let drive = URL(string: "gdrive://\(UUID().uuidString)/my-drive")!
        #expect(PreviewSource.retryDelay(for: drive) == 5 && PreviewSource.isProgressive(drive))
        await #expect(throws: (any Error).self) { try await PreviewSource.localFile(for: URL(string: "recent:/files")!, thumbnail: true) }
    }
}

/// Downloads wait for `gate`, the first one at least; `names` are the files asked for.
private final class GatedPreviewServer: RemoteProvider, @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var asked: [String] = []
    var names: [String] { lock.withLock { asked } }

    func download(_ remote: URL, into localFolder: URL) throws -> URL {
        lock.withLock { asked.append(remote.lastPathComponent) }
        gate.wait()
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let local = localFolder.appendingPathComponent(remote.lastPathComponent)
        try Data(count: 4).write(to: local)
        return local
    }
    func list(_ folder: URL) throws -> [FileItem] { [] }
    func upload(_ local: URL, into remoteFolder: URL) throws { throw CocoaError(.featureUnsupported) }
    func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
    func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
    func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
    func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func rootTitle(_ url: URL) -> String { "preview" }
}
