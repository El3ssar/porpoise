import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Previews of items not on this Mac come from one place: a server's file as a temporary copy (removed by whoever
/// made the preview), a cloud service's own preview, and when to ask again after a failure.
// These use unique, locked provider registrations and temporary copies; none reads or changes Settings.store.
@Suite(.serialized) struct PreviewSourceTests {
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
        defer { server.open() }
        let first = Task { try await Self.copyAndRemove(root.appendingPathComponent("a.jpg")) }
        try await awaitCallback { server.whenStarted($0) }
        let second = Task { try await PreviewSource.localFile(for: root.appendingPathComponent("b.jpg"), thumbnail: true) }
        second.cancel()
        server.open()
        try await first.value
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(server.names == ["a.jpg"])
    }

    /// A blocked connection must not prevent another server's preview from finishing.
    @Test(.timeLimit(.minutes(2))) func anUnrelatedServerDoesNotWaitForABlockedPreview() async throws {
        let slowRoot = URL(string: "sftp://preview-slow-\(UUID().uuidString.lowercased()).invalid/")!
        let fastRoot = URL(string: "sftp://preview-fast-\(UUID().uuidString.lowercased()).invalid/")!
        let slow = GatedPreviewServer(), fast = MemoryServer(root: fastRoot)
        fast.add("photo.jpg", size: 4)
        RemoteFS.use(slow, for: slowRoot)
        RemoteFS.use(fast, for: fastRoot)
        defer {
            slow.open()
            RemoteFS.use(nil, for: slowRoot)
            RemoteFS.use(nil, for: fastRoot)
        }
        let first = Task { try await Self.copyAndRemove(slowRoot.appendingPathComponent("a.jpg")) }
        try await awaitCallback { slow.whenStarted($0) }
        let other = Task { try await Self.copyAndRemove(fastRoot.appendingPathComponent("photo.jpg")) }
        var failure: Error?
        do {
            try await awaitCallback("An unrelated server's preview waited for the blocked connection") { (done: Callback<Void>) in
                Task { done.resume(with: await other.result) }
            }
        } catch { failure = error }
        // Drain both tasks even on failure; no held transfer or temporary copy survives this test.
        slow.open()
        try await first.value
        _ = await other.result
        if let failure { throw failure }
    }

    private static func copyAndRemove(_ remote: URL) async throws {
        let local = try await PreviewSource.localFile(for: remote, thumbnail: true)
        try FileManager.default.removeItem(at: try #require(local.cleanup))
    }

    @Test func cloudPreviewsAreAskedForAgainSoon() async {
        let drive = URL(string: "gdrive://\(UUID().uuidString)/my-drive")!
        #expect(PreviewSource.retryDelay(for: drive) == 5 && PreviewSource.isProgressive(drive))
        await #expect(throws: (any Error).self) { try await PreviewSource.localFile(for: URL(string: "recent:/files")!, thumbnail: true) }
    }
}

/// Downloads wait until `open()`; readiness is a callback, and opening also releases any future mistaken fetch.
private final class GatedPreviewServer: RemoteProvider, @unchecked Sendable {
    private let gate = DispatchGroup()
    private let lock = NSLock()
    private var isOpen = false
    private var started: Callback<Void>?
    private var asked: [String] = []
    var names: [String] { lock.withLock { asked } }

    init() { gate.enter() }

    func whenStarted(_ callback: Callback<Void>) {
        let alreadyStarted = lock.withLock {
            if !asked.isEmpty { return true }
            started = callback
            return false
        }
        if alreadyStarted { callback.resume() }
    }

    func open() {
        lock.withLock {
            guard !isOpen else { return }
            isOpen = true
            gate.leave()
        }
    }

    func download(_ remote: URL, into localFolder: URL) throws -> URL {
        let callback = lock.withLock {
            asked.append(remote.lastPathComponent); return started
        }
        callback?.resume()
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
