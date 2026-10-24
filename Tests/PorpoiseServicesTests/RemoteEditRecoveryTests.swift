import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor
@Suite(.serialized, .isolatedSettings)
struct RemoteEditRecoveryTests {
    @Test func cacheIdentitySeparatesAccountsAndPorts() throws {
        let cache = try Scratch("remote-edit-identity")
        RemoteFS.cacheParentOverride = cache.url
        defer { RemoteFS.cacheParentOverride = nil }
        let alice = URL(string: "sftp://alice@example.invalid:2222/work/report.txt")!
        let bob = URL(string: "sftp://bob@example.invalid:2200/work/report.txt")!
        #expect(RemoteOpener.cacheFolder(for: alice) != RemoteOpener.cacheFolder(for: bob))
        #expect(
            RemoteOpener.cacheFolder(for: alice) != RemoteOpener.cacheFolder(for: URL(string: "sftp://alice@example.invalid:2200/work/report.txt")!))
        #expect(
            RemoteOpener.cacheFolder(for: alice) != RemoteOpener.cacheFolder(for: URL(string: "sftp://bob@example.invalid:2222/work/report.txt")!))
        #expect(
            RemoteOpener.cacheFolder(for: alice) != RemoteOpener.cacheFolder(for: URL(string: "ftp://alice@example.invalid:2222/work/report.txt")!))
    }

    @Test func offlineReopenKeepsPreviousProcessBytes() async throws {
        let cache = try Scratch("remote-edit-recovery")
        RemoteFS.cacheParentOverride = cache.url
        let remote = URL(string: "sftp://recovery.invalid/draft.txt")!
        let provider = UnavailableEditProvider()
        RemoteFS.use(provider, for: remote)
        defer { RemoteFS.cacheParentOverride = nil; RemoteFS.use(nil, for: remote) }
        let folder = RemoteOpener.cacheFolder(for: remote)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent("draft.txt")
        try Data("unsent edits".utf8).write(to: local)
        RemoteOpener.open(FileItem(url: remote, name: "draft.txt", isDirectory: false), using: { _ in })
        // Wait for the attempted download to complete, without relying on a sleep racing its deletion.
        await expectEventually("offline attempt") { provider.attempted }
        #expect((try? String(contentsOf: local, encoding: .utf8)) == "unsent edits")
    }
}

private final class UnavailableEditProvider: RemoteProvider {
    private let lock = NSLock()
    private var didAttempt = false
    var attempted: Bool { lock.withLock { didAttempt } }
    func list(_ folder: URL) throws -> [FileItem] { [] }
    func download(_ remote: URL, into folder: URL) throws -> URL {
        lock.withLock { didAttempt = true }; throw URLError(.notConnectedToInternet)
    }
    func upload(_ local: URL, into folder: URL) throws { throw URLError(.notConnectedToInternet) }
    func delete(_ urls: [URL]) throws {}
    func makeFolder(_ url: URL) throws {}
    func rename(_ url: URL, to name: String) throws {}
    func move(_ urls: [URL], into folder: URL) throws {}
    func copy(_ urls: [URL], into folder: URL) throws {}
    func rootTitle(_ url: URL) -> String { "Test" }
}

@Suite struct RemoteOpenCopyTests {
    private let remote = URL(string: "sftp://user@copies.invalid:2222/draft.txt")!

    @Test func canonicalIdentitySeparatesAccountsAndImplicitPortsWithoutPasswords() {
        let a = URL(string: "sftp://user:password@HOST.invalid/file.txt")!
        let b = URL(string: "sftp://user@host.invalid/file.txt")!
        #expect(RemoteOpenCopyStore.identity(a) == RemoteOpenCopyStore.identity(b))
        #expect(RemoteOpenCopyStore.identity(b) != RemoteOpenCopyStore.identity(URL(string: "sftp://user@host.invalid:22/file.txt")!))
        #expect(RemoteOpenCopyStore.identity(b) != RemoteOpenCopyStore.identity(URL(string: "sftp://other@host.invalid/file.txt")!))
    }

    @Test func everyOpenChecksCurrentBytesAndKeepsEarlierEdits() async throws {
        let root = try Scratch("remote-copy-fresh"), provider = CopyEditProvider()
        let store = RemoteOpenCopyStore(remote: remote, root: root.url)
        let first = try await store.open(provider: provider)
        #expect(try await store.open(provider: provider) == first)
        #expect(provider.downloads == 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.path)
        try Data("my local edit".utf8).write(to: first)
        provider.content = "new server bytes"
        let second = try await store.open(provider: provider)
        #expect(second != first)
        #expect(try String(contentsOf: second, encoding: .utf8) == "new server bytes")
        #expect(try String(contentsOf: first, encoding: .utf8) == "my local edit")
        #expect((try FileManager.default.attributesOfItem(atPath: second.path)[.posixPermissions] as? NSNumber)?.intValue == 0o444)
        provider.failDownload = true
        await #expect(throws: URLError.self) { try await store.open(provider: provider) }
        #expect(try String(contentsOf: first, encoding: .utf8) == "my local edit")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder.path).count == 2)
    }
    @Test func previewCopiesAreIndependentFromCacheAndPreserveExportName() async throws {
        let root = try Scratch("remote-copy-preview")
        let cached = root.url.appendingPathComponent("export.pdf")
        try Data("cloud bytes".utf8).write(to: cached)
        let store = RemoteOpenCopyStore(remote: remote, root: root.url.appendingPathComponent("Copies"))
        let opened = try await store.copy(cached)
        #expect(opened != cached && opened.lastPathComponent == "export.pdf")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: opened.path)
        try Data("local annotation".utf8).write(to: opened)
        #expect(try String(contentsOf: cached, encoding: .utf8) == "cloud bytes")
        let next = try await store.copy(cached)
        #expect(next != opened)
        #expect(try String(contentsOf: opened, encoding: .utf8) == "local annotation")
    }
    @Test func sweepOnlyRemovesOldUnchangedReadOnlyOwnedCopies() throws {
        struct Record: Encodable {
            let version = 1
            let name: String
            let fingerprint: JobJournal.Fingerprint
            let hash: String
            let created: Date
        }
        let root = try Scratch("remote-copy-sweep"), store = RemoteOpenCopyStore(remote: remote, root: root.url)
        func seed(age: TimeInterval, changed: Bool, writable: Bool) throws -> URL {
            let folder = store.folder.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let content = folder.appendingPathComponent("Content", isDirectory: true)
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false)
            let local = content.appendingPathComponent("draft.txt")
            try Data("original".utf8).write(to: local)
            let record = Record(
                name: local.lastPathComponent, fingerprint: try #require(JobJournal.Fingerprint(local)),
                hash: try FileChecksums.digest(local), created: Date().addingTimeInterval(-age))
            try JSONEncoder().encode(record).write(to: folder.appendingPathComponent(".porpoise-copy.json"))
            if changed { try Data("edited".utf8).write(to: local) }
            try FileManager.default.setAttributes([.posixPermissions: writable ? 0o600 : 0o444], ofItemAtPath: local.path)
            return local
        }
        let old = try seed(age: 8 * 86400, changed: false, writable: false)
        let fresh = try seed(age: 60, changed: false, writable: false)
        let changed = try seed(age: 8 * 86400, changed: true, writable: false)
        let unlocked = try seed(age: 8 * 86400, changed: false, writable: true)
        try store.sweep()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        for kept in [fresh, changed, unlocked] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
    }
}

private class CopyEditProvider: RemoteProvider, @unchecked Sendable {
    let lock = NSRecursiveLock()
    var afterDownload: () throws -> Void = {}
    var beforePublish: () throws -> Void = {}
    var failDownload = false
    private var downloadCount = 0
    private var uploadCount = 0
    var downloads: Int { lock.withLock { downloadCount } }
    var uploads: Int { lock.withLock { uploadCount } }
    var text: String { lock.withLock { content } }
    var content = "server"
    func list(_ folder: URL) throws -> [FileItem] { [] }
    func download(_ remote: URL, into folder: URL) throws -> URL {
        try lock.withLock {
            downloadCount += 1
            if failDownload { throw URLError(.notConnectedToInternet) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let local = folder.appendingPathComponent(remote.lastPathComponent)
            try Data(content.utf8).write(to: local); try afterDownload()
            return local
        }
    }
    func upload(_ local: URL, into folder: URL) throws { lock.withLock { uploadCount += 1 } }
    func delete(_ urls: [URL]) throws {}
    func makeFolder(_ url: URL) throws {}
    func rename(_ url: URL, to name: String) throws {}
    func move(_ urls: [URL], into folder: URL) throws {}
    func copy(_ urls: [URL], into folder: URL) throws {}
    func rootTitle(_ url: URL) -> String { "Test server" }
}
