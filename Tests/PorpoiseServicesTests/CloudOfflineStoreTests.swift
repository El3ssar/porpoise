import CryptoKit
import Foundation
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

final class FakeContentSource: CloudContentSource, @unchecked Sendable {
    let accountID = "fixture"
    let providerTitle = "Fixture Cloud"
    private let lock = NSLock()
    var isOffline = false
    var onChanges: (@Sendable (CloudChangeBatch) -> Void)?
    var items: [String: CloudRemoteItem] = [:]
    var bytes: [String: Data] = [:]
    var downloads = 0
    var active = 0
    var maximum = 0
    var offsets: [Int] = []
    var failAfterPartial = false
    var delay: Duration = .milliseconds(2)
    func add(_ id: String, parent: String? = nil, folder: Bool = false, text: String = "hello", revision: String = "r1") -> CloudRemoteItem {
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
    func ref(for url: URL) -> CloudItemRef? { url.scheme == "fixture" ? .init(account: accountID, item: url.lastPathComponent) : nil }
    func url(for item: CloudRemoteItem) -> URL { URL(string: "fixture://fixture/" + item.ref.item)! }
    func cachedItem(_ ref: CloudItemRef) -> CloudRemoteItem? { lock.withLock { items[ref.item] } }
    func item(_ ref: CloudItemRef) async throws -> CloudRemoteItem {
        guard !isOffline else { throw CloudContentError.offline }
        guard let item = cachedItem(ref) else { throw CloudContentError.notFound }
        return item
    }
    func children(_ folder: CloudItemRef) async throws -> [CloudRemoteItem] {
        lock.withLock { items.values.filter { $0.parents.contains(folder.item) } }
    }
    func download(_ item: CloudRemoteItem, to partial: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let data = lock.withLock { () -> Data in
            downloads += 1; active += 1; maximum = max(maximum, active); return bytes[item.ref.item]!
        }
        defer { lock.withLock { active -= 1 } }
        let offset = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        lock.withLock { offsets.append(offset) }
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

struct CloudOfflineStoreTests {
    func store(
        _ source: FakeContentSource, _ scratch: Scratch, limit: Int64? = nil,
        free: @escaping @Sendable () -> (Int64, Int64) = { (100_000_000_000, 200_000_000_000) },
        held: @escaping @Sendable (CloudItemRef) async -> Bool = { _ in false }
    ) throws -> CloudOfflineStore {
        try CloudOfflineStore(
            source: source, directory: scratch.url.appendingPathComponent("Offline"), recentLimit: limit,
            freeSpace: free, held: held)
    }
    @Test func verifiedFetchRelaunchAndCorruption() async throws {
        let source = FakeContentSource(), scratch = try Scratch(), item = source.add("one")
        let store = try store(source, scratch)
        let url = try await store.fetch(item)
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        #expect(try await store.fetch(item) == url)
        #expect(source.downloads == 1)
        #expect(try await store.localCopy(item.ref, revision: "wrong") == nil)
        #expect(await store.snapshot().usage == CloudOfflineUsage(recent: 5))
        let relaunched = try self.store(source, scratch)
        #expect(try await relaunched.localCopy(item.ref, revision: "r1") == url)
        #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == 5)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        try Data("bad".utf8).write(to: store.directory.appendingPathComponent("index.json"))
        let rebuilt = try self.store(source, scratch)
        #expect(await rebuilt.snapshot().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func checksumMismatchNeverPublishesAndPartialResumes() async throws {
        let source = FakeContentSource(), scratch = try Scratch()
        var item = source.add("one")
        let store = try store(source, scratch)
        source.failAfterPartial = true
        await #expect(throws: CancellationError.self) { try await store.fetch(item, keep: true) }
        #expect(await store.snapshot().pins.contains("one"))
        _ = try await store.fetch(item)
        #expect(source.offsets == [0, 2])
        item.revision = "r2"; item.checksum = .md5("bad")
        await #expect(throws: CloudContentError.checksum) { try await store.fetch(item) }
        #expect(await store.snapshot().entries["one"]?.item.revision == "r1")
        #expect(await store.snapshot().errors["one"] != nil)
    }
    @Test func inheritanceLRUAndHeldEdits() async throws {
        let source = FakeContentSource(), scratch = try Scratch()
        let folder = source.add("folder", folder: true)
        let kept = source.add("kept", parent: "folder"), held = source.add("held"), recent = source.add("recent")
        let store = try store(source, scratch, limit: 0, held: { $0.item == "held" })
        try await store.remember([folder]); try await store.pin([folder.ref])
        _ = try await store.fetch(kept); _ = try await store.fetch(held); _ = try await store.fetch(recent)
        #expect(await store.snapshot().inheritedPin("kept") == "folder")
        #expect(await store.snapshot().usage.kept == 5)
        await #expect(throws: CloudContentError.heldForEditing) { try await store.remove([held.ref]) }
        await #expect(throws: CloudContentError.self) { try await store.remove([kept.ref]) }
        try await store.setRecentLimit(0)
        #expect(await store.snapshot().entries["recent"] == nil)
        #expect(await store.snapshot().entries["held"] != nil)
        #expect(await store.snapshot().entries["kept"] != nil)
        try await store.unpin([folder.ref])
        #expect(await store.snapshot().entries["kept"] == nil)
    }
    @Test func lowSpacePausesAndResumesWithoutLosingPin() async throws {
        let source = FakeContentSource(), scratch = try Scratch(), item = source.add("one")
        let space = LockedOfflineSpace()
        let store = try store(source, scratch, free: { space.get() })
        await #expect(throws: CloudContentError.lowSpace) { try await store.fetch(item, keep: true) }
        #expect(source.downloads == 0)
        #expect(await store.snapshot().pins.contains("one"))
        space.set(10_000_000_000)
        _ = try await store.fetch(item)
        #expect(source.downloads == 1)
        try await store.wipe()
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        #expect(await store.snapshot().entries.isEmpty)
    }
    /// A "/" in a cloud name (also one a combining mark hides) becomes ":": one file, inside the store.
    @Test func cloudNamesStayOneFileInsideTheStore() async throws {
        let source = FakeContentSource(), scratch = try Scratch()
        let store = try store(source, scratch)
        let input = scratch.url.appendingPathComponent("input")
        try Data("hello".utf8).write(to: input)
        for (i, (name, local)) in [("../escape", "..:escape"), ("../\u{301}x", "..:\u{301}x"), ("back\\slash", "back\\slash")].enumerated() {
            var odd = source.add("odd\(i)"); odd.name = name
            let copy = try await store.adopt(file: input, as: odd)
            #expect(copy.lastPathComponent == local, "\(name)")
            #expect(copy.resolvingSymlinksInPath().path.hasPrefix(store.directory.resolvingSymlinksInPath().path + "/objects/"), "\(name)")
        }
    }
    @Test func adoptUsesIndependentInodeAndRejectsWrongSize() async throws {
        let source = FakeContentSource(), scratch = try Scratch(), item = source.add("one")
        let store = try store(source, scratch)
        let input = scratch.url.appendingPathComponent("edit")
        try Data("hello".utf8).write(to: input)
        let copy = try await store.adopt(file: input, as: item)
        let fm = FileManager.default
        #expect(
            try fm.attributesOfItem(atPath: input.path)[.systemFileNumber] as? Int != fm.attributesOfItem(atPath: copy.path)[.systemFileNumber]
                as? Int)
        try Data("modified".utf8).write(to: input)
        #expect(try Data(contentsOf: copy) == Data("hello".utf8))
        await #expect(throws: CloudContentError.checksum) { try await store.adopt(file: input, as: item) }
    }
}

final class LockedOfflineSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int64 = 0
    func get() -> (Int64, Int64) { lock.withLock { (available, 20_000_000_000) } }
    func set(_ value: Int64) { lock.withLock { available = value } }
}

extension CloudOfflineStoreTests {
    @Test func duplicateFetchesShareBytesAndPinsSurviveOfflineRelaunch() async throws {
        let source = FakeContentSource(), scratch = try Scratch(), item = source.add("one")
        let store = try store(source, scratch)
        async let first = store.fetch(item)
        async let second = store.fetch(item)
        let (a, b) = try await (first, second)
        #expect(a == b && source.downloads == 1)
        #expect(await store.state(item.ref) == .downloaded)
        try await store.pin([item.ref])
        #expect(await store.state(item.ref) == .kept)
        source.isOffline = true
        #expect(try await store.fetch(item) == a)
        let next = source.add("next")
        await #expect(throws: CloudContentError.offline) { try await store.fetch(next, keep: true) }
        let relaunched = try self.store(source, scratch)
        #expect(await relaunched.snapshot().pins.contains("next"))
        #expect(await relaunched.usage().kept == 5)
        try FileManager.default.removeItem(at: a)
        #expect(try await store.localCopy(item.ref, revision: item.revision) == nil)
    }
    @Test func checksumsInvalidNamesAccountsAndChangedRevision() async throws {
        let source = FakeContentSource(), scratch = try Scratch(), item = source.add("one")
        let store = try store(source, scratch)
        let input = scratch.url.appendingPathComponent("input")
        try Data("hello".utf8).write(to: input)
        let sha = SHA256.hash(data: Data("hello".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(try CloudChecksum.sha256(sha).verify(input))
        #expect(try !CloudChecksum.sha256("wrong").verify(input))
        #expect(try !CloudChecksum.dropbox("x").verify(input))
        #expect(throws: CloudContentError.unsupported) { try CloudChecksum.quickXor("x").verify(input) }
        var other = item; other.ref.account = "other"
        await #expect(throws: CloudContentError.unsupported) { try await store.fetch(other) }
        await #expect(throws: CloudContentError.unsupported) { try await store.remember([other]) }
        for name in ["", ".", "..", "bad\0name", "new\nline"] {
            var bad = item; bad.name = name
            await #expect(throws: CloudContentError.unsupported) { try await store.adopt(file: input, as: bad) }
        }
        #expect(await store.state(item.ref) == .cloudOnly)
        let url = try await store.fetch(item)
        try Data("truncated".utf8).write(to: url)
        let relaunched = try self.store(source, scratch)
        #expect(await relaunched.snapshot().entries.isEmpty)
        for error in [CloudContentError.unsupported, .offline, .notFound, .changed, .checksum, .lowSpace, .heldForEditing, .unavailable("Reason")] {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}

extension CloudOfflineStoreTests {
    @Test func aNewRevisionWaitsForOldFlightAndStillDeduplicates() async throws {
        let source = FakeContentSource(), scratch = try Scratch(), first = source.add("one")
        source.delay = .milliseconds(100)
        let store = try store(source, scratch)
        let firstFetch = Task { try await store.fetch(first) }
        _ = await poll(timeout: 5) { source.active != 0 }
        #expect(source.active == 1)
        let updated = source.add("one", text: "updated", revision: "r2")
        async let a = store.fetch(updated)
        async let b = store.fetch(updated)
        _ = try await firstFetch.value
        let (one, two) = try await (a, b)
        #expect(one == two && source.downloads == 2)
        #expect(try Data(contentsOf: one) == Data("updated".utf8))
        #expect(await store.snapshot().entries["one"]?.item.revision == "r2")
        #expect(await store.state(updated.ref) == .downloaded)
    }
}

extension CloudOfflineStoreTests {
    @Test func concurrentDownloadsReserveSpaceUntilTheirCopyCommits() async throws {
        let source = FakeContentSource(), scratch = try Scratch()
        let first = source.add("first"), second = source.add("second")
        source.delay = .milliseconds(100)
        let store = try store(source, scratch, free: { (2_000_000_008, 20_000_000_000) })
        let running = Task { try await store.fetch(first) }
        _ = await poll(timeout: 5) { source.active != 0 }
        #expect(source.active == 1)
        await #expect(throws: CloudContentError.lowSpace) { try await store.fetch(second, keep: true) }
        #expect(await store.state(second.ref) == .error(CloudContentError.lowSpace.localizedDescription))
        _ = try await running.value
        _ = try await store.fetch(second)
        #expect(source.downloads == 2 && source.maximum == 1)
        #expect(await store.state(second.ref) == .kept)
    }
}

extension CloudOfflineStoreTests {
    @Test func removalAndWipeDrainFlightsAndDeletePartialBytes() async throws {
        let source = FakeContentSource(), scratch = try Scratch(), item = source.add("one")
        let store = try store(source, scratch)
        source.failAfterPartial = true
        await #expect(throws: CancellationError.self) { try await store.fetch(item, keep: true) }
        let object = store.directory.appendingPathComponent("objects").appendingPathComponent(cloudObjectKey(item.ref.item))
        #expect(FileManager.default.fileExists(atPath: object.path))
        try await store.remove([item.ref])
        #expect(!FileManager.default.fileExists(atPath: object.path))
        source.delay = .seconds(5)
        let task = Task { try await store.fetch(item, keep: true) }
        _ = await poll(timeout: 5) { source.active != 0 }
        try await store.wipe()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        await #expect(throws: CancellationError.self) { try await store.fetch(item) }
        await #expect(throws: CancellationError.self) { try await store.unpin([item.ref]) }
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }
}
