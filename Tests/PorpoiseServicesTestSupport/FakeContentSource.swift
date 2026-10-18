import CryptoKit
import Foundation
import PorpoiseCore

@testable import PorpoiseServices

/// A cloud account's content, in memory: what the offline store and its tests download, keep and follow.
public final class FakeContentSource: CloudContentSource, @unchecked Sendable {
    public let accountID = "fixture"
    public let providerTitle = "Fixture Cloud"
    private let lock = NSLock()
    public var isOffline = false
    public var onChanges: (@Sendable (CloudChangeBatch) -> Void)?
    public var items: [String: CloudRemoteItem] = [:]
    public var bytes: [String: Data] = [:]
    private var downloadCount = 0
    private var activeCount = 0
    private var maximumCount = 0
    private var recordedOffsets: [Int] = []
    public var downloads: Int { lock.withLock { downloadCount } }
    public var active: Int { lock.withLock { activeCount } }
    public var maximum: Int { lock.withLock { maximumCount } }
    public var offsets: [Int] { lock.withLock { recordedOffsets } }
    /// Emitted only after the download owns its immutable byte snapshot, before a hold can suspend it.
    public let capturedDownloads: AsyncStream<CloudRemoteItem>
    private let captured: AsyncStream<CloudRemoteItem>.Continuation
    public var failAfterPartial = false
    public var delay: Duration = .milliseconds(2)
    private var holds = false
    private var heldDownloads: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// While true, downloads that have taken their bytes wait before writing them: a test's download stays under way
    /// (and `active`) until it sets this back or cancels the download, however slowly the test gets to run.
    public var holdsDownloads: Bool {
        get { lock.withLock { holds } }
        set {
            let waiting: [CheckedContinuation<Void, Error>] = lock.withLock {
                holds = newValue
                guard !newValue else { return [] }
                let waiting = Array(heldDownloads.values)
                heldDownloads.removeAll()
                return waiting
            }
            for continuation in waiting { continuation.resume() }
        }
    }
    public init() {
        let events = AsyncStream<CloudRemoteItem>.makeStream(bufferingPolicy: .bufferingNewest(32))
        capturedDownloads = events.stream; captured = events.continuation
    }
    deinit { captured.finish() }

    private func waitForRelease() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let ready: Result<Void, Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if !holds { return .success(()) }
                    heldDownloads[id] = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.heldDownloads.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
    public func add(_ id: String, parent: String? = nil, folder: Bool = false, text: String = "hello", revision: String = "r1") -> CloudRemoteItem {
        let data = Data(text.utf8)
        let item = CloudRemoteItem(
            ref: .init(account: accountID, item: id), name: id + ".txt", parents: parent.map { [$0] } ?? [],
            isFolder: folder, size: folder ? nil : Int64(data.count), revision: revision,
            checksum: folder ? nil : .md5(Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        lock.withLock {
            items[id] = item; bytes[id] = data
        }
        return item
    }
    public func ref(for url: URL) -> CloudItemRef? { url.scheme == "fixture" ? .init(account: accountID, item: url.lastPathComponent) : nil }
    public func url(for item: CloudRemoteItem) -> URL { URL(string: "fixture://fixture/" + item.ref.item)! }
    public func cachedItem(_ ref: CloudItemRef) -> CloudRemoteItem? { lock.withLock { items[ref.item] } }
    public func item(_ ref: CloudItemRef) async throws -> CloudRemoteItem {
        guard !isOffline else { throw CloudContentError.offline }
        guard let item = cachedItem(ref) else { throw CloudContentError.notFound }
        return item
    }
    public func children(_ folder: CloudItemRef) async throws -> [CloudRemoteItem] {
        lock.withLock { items.values.filter { $0.parents.contains(folder.item) } }
    }
    public func download(_ item: CloudRemoteItem, to partial: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let data = lock.withLock { () -> Data in
            downloadCount += 1; activeCount += 1; maximumCount = max(maximumCount, activeCount); return bytes[item.ref.item]!
        }
        defer { lock.withLock { activeCount -= 1 } }
        captured.yield(item)
        try await waitForRelease()
        let offset = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        lock.withLock { recordedOffsets.append(offset) }
        if failAfterPartial {
            try data.prefix(2).write(to: partial); failAfterPartial = false; throw CancellationError()
        }
        try await Task.sleep(for: delay)
        if !FileManager.default.fileExists(atPath: partial.path) { _ = FileManager.default.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data.dropFirst(offset))
        try handle.synchronize()
        progress(Int64(data.count), Int64(data.count))
    }
}
