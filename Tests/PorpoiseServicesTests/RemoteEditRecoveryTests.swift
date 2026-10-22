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

@MainActor
@Suite(.serialized, .isolatedSettings)
struct RemoteEditSessionTests {
    let remote = URL(string: "sftp://user@session.invalid:2222/draft.txt")!

    @Test func reconstructedStoreKeepsEditsOffline() async throws {
        let root = try Scratch("remote-session-restart"), provider = RevisionEditProvider()
        let store = RemoteEditSessionStore(remote: remote, root: root.url)
        let local = try await store.open(provider: provider)
        try Data("unsent edit".utf8).write(to: local, options: .atomic)
        provider.failDownload = true
        let recovered = RemoteEditSessionStore(remote: remote, root: root.url)
        #expect(try await recovered.open(provider: provider) == local)
        #expect(try String(contentsOf: local, encoding: .utf8) == "unsent edit")
        #expect(provider.downloads == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: local.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(!String(data: try Data(contentsOf: store.folder.appendingPathComponent("session.json")), encoding: .utf8)!.contains("password"))
    }

    @Test func failedPublicationRetainsImmutableSnapshotAndNewerEdits() async throws {
        let root = try Scratch("remote-session-snapshot"), provider = RevisionEditProvider()
        let store = RemoteEditSessionStore(remote: remote, root: root.url)
        let local = try await store.open(provider: provider)
        try Data("v2".utf8).write(to: local)
        provider.beforePublish = {
            try Data("v3".utf8).write(to: local, options: .atomic)
            throw URLError(.networkConnectionLost)
        }
        await #expect(throws: URLError.self) { try await store.save(provider: provider) }
        let recordURL = store.folder.appendingPathComponent("session.json")
        let saved = try JSONDecoder().decode(RemoteEditSession.self, from: Data(contentsOf: recordURL))
        let id = try #require(saved.uploadID)
        let snapshot = store.folder.appendingPathComponent("Uploads/" + id.uuidString + "/draft.txt")
        #expect(try String(contentsOf: snapshot, encoding: .utf8) == "v2")
        provider.beforePublish = {}
        let recovered = RemoteEditSessionStore(remote: remote, root: root.url)
        #expect(try await recovered.save(provider: provider))
        #expect(provider.text == "v2")
        #expect(try String(contentsOf: local, encoding: .utf8) == "v3")
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try await !recovered.save(provider: provider))
        #expect(provider.text == "v3")
        let count = provider.publications
        #expect(try await !recovered.save(provider: provider))
        #expect(provider.publications == count)
    }

    @Test func remoteConflictRetainsBothVersions() async throws {
        let root = try Scratch("remote-session-conflict"), provider = RevisionEditProvider()
        let store = RemoteEditSessionStore(remote: remote, root: root.url)
        let local = try await store.open(provider: provider)
        try Data("mine".utf8).write(to: local)
        provider.replaceRemote("theirs")
        await #expect(throws: RemoteEditError.self) { try await store.save(provider: provider) }
        #expect(provider.text == "theirs")
        #expect(try String(contentsOf: local, encoding: .utf8) == "mine")
    }

    @Test func changedRemoteDuringDownloadIsNotAnEditingBaseline() async throws {
        let root = try Scratch("remote-session-freshness"), provider = RevisionEditProvider()
        let store = RemoteEditSessionStore(remote: remote, root: root.url)
        provider.afterDownload = { provider.replaceRemote("new generation") }
        await #expect(throws: RemoteEditError.self) { try await store.open(provider: provider) }
        #expect(!FileManager.default.fileExists(atPath: store.local.path))
        #expect(provider.publications == 0)
    }

    @Test func damagedRecordsAndUnownedWorkingCopiesAreKept() async throws {
        let root = try Scratch("remote-session-damaged"), provider = RevisionEditProvider()
        let store = RemoteEditSessionStore(remote: remote, root: root.url)
        let local = try await store.open(provider: provider)
        let recordURL = store.folder.appendingPathComponent("session.json")
        try Data("damaged".utf8).write(to: recordURL)
        await #expect(throws: RemoteEditError.self) { try await store.open(provider: provider) }
        #expect(try String(contentsOf: local, encoding: .utf8) == "server")
        try FileManager.default.removeItem(at: recordURL)
        await #expect(throws: RemoteEditError.self) { try await store.open(provider: provider) }
        #expect(try String(contentsOf: local, encoding: .utf8) == "server")
        await #expect(throws: RemoteEditError.self) { try await store.save(provider: provider) }
    }

    @Test func noConditionalCapabilityMeansCopyOnly() async throws {
        let root = try Scratch("remote-session-copy"), provider = CopyEditProvider()
        let store = RemoteEditSessionStore(remote: remote, root: root.url)
        let local = try await store.open(provider: provider)
        try Data("local edit".utf8).write(to: local)
        await #expect(throws: RemoteEditError.self) { try await store.save(provider: provider) }
        #expect(provider.uploads == 0)
        #expect(try String(contentsOf: local, encoding: .utf8) == "local edit")
        #expect(RemoteEditError.copyOnly.localizedDescription.contains("stays on this Mac"))
        #expect(RemoteEditError.changed.localizedDescription.contains("changed"))
        #expect(RemoteEditError.damaged.localizedDescription.contains("kept"))
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

private final class RevisionEditProvider: CopyEditProvider, RemoteEditPublishing, @unchecked Sendable {
    private var revision = 1
    private var publicationCount = 0
    var publications: Int { lock.withLock { publicationCount } }
    func replaceRemote(_ text: String) {
        lock.withLock {
            content = text; revision += 1
        }
    }
    func editRevision(_ remote: URL) throws -> String { lock.withLock { String(revision) } }
    func publishEdit(_ local: URL, to remote: URL, expectedRevision: String) throws -> String {
        try lock.withLock {
            try beforePublish()
            guard expectedRevision == String(revision) else { throw RemoteEditError.changed }
            content = try String(contentsOf: local, encoding: .utf8)
            revision += 1; publicationCount += 1
            return String(revision)
        }
    }
}

@MainActor
@Suite(.serialized, .isolatedSettings)
struct RemoteEditIntegrationTests {
    @Test func concurrentOpenDownloadsOnceAndShowsActivity() async throws {
        let root = try Scratch("remote-edit-coalescing"), provider = CopyEditProvider()
        let remote = URL(string: "sftp://coalesce.invalid/file.txt")!
        RemoteFS.cacheParentOverride = root.url; RemoteFS.use(provider, for: remote)
        defer { RemoteFS.cacheParentOverride = nil; RemoteFS.use(nil, for: remote) }
        var opened: [URL] = []
        let item = FileItem(url: remote, name: "file.txt", isDirectory: false)
        RemoteOpener.open(item, using: { opened.append($0) })
        RemoteOpener.open(item, using: { opened.append($0) })
        await expectEventually("both open requests") { opened.count == 2 }
        #expect(provider.downloads == 1)
        #expect(opened.first == opened.last)
        #expect(FileOperationsController.shared.activities.contains { $0.sources == [remote] && $0.state == .completed })
    }

    @Test func conditionalPublisherWatchesRepeatedAtomicReplacements() async throws {
        let root = try Scratch("remote-edit-watching"), provider = RevisionEditProvider()
        let remote = URL(string: "sftp://watch.invalid/file.txt")!
        RemoteFS.cacheParentOverride = root.url; RemoteFS.use(provider, for: remote)
        defer { RemoteFS.cacheParentOverride = nil; RemoteFS.use(nil, for: remote) }
        var local: URL?
        RemoteOpener.open(FileItem(url: remote, name: "file.txt", isDirectory: false), using: { local = $0 })
        await expectEventually("opened") { local != nil }
        let url = try #require(local)
        for text in ["v2", "v3"] {
            try Data(text.utf8).write(to: url, options: .atomic)
            await expectEventually("conditional save") { provider.text == text }
        }
        #expect(provider.uploads == 0)
        #expect(FileOperationsController.shared.activities.contains { $0.sources == [remote] && $0.cloudTitle == "Saving “file.txt”" })
    }

    @Test func cancellationBeforePublicationKeepsWorkingFile() async throws {
        let root = try Scratch("remote-edit-cancel"), provider = RevisionEditProvider()
        let remote = URL(string: "sftp://cancel.invalid/file.txt")!
        let store = RemoteEditSessionStore(remote: remote, root: root.url)
        let local = try await store.open(provider: provider)
        try Data("draft".utf8).write(to: local)
        let context = CloudTransferContext(checkpoint: { throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await store.save(provider: provider, context: context) }
        #expect(provider.text == "server")
        #expect(try String(contentsOf: local, encoding: .utf8) == "draft")
    }

    @Test func backgroundCallerOpensOnMainActor() async throws {
        let root = try Scratch("remote-edit-background"), provider = CopyEditProvider()
        let remote = URL(string: "sftp://background.invalid/file.txt")!
        RemoteFS.cacheParentOverride = root.url; RemoteFS.use(provider, for: remote)
        let previous = RemoteOpener.openFile
        defer { RemoteFS.cacheParentOverride = nil; RemoteFS.use(nil, for: remote); RemoteOpener.openFile = previous }
        var opened: URL?, onMain = false
        RemoteOpener.openFile = {
            opened = $0; onMain = Thread.isMainThread
        }
        await offThePool { RemoteOpener.open(FileItem(url: remote, name: "file.txt", isDirectory: false)) }
        await expectEventually("background open") { opened != nil }
        #expect(onMain)
    }

    @Test func canonicalIdentityIgnoresPasswordAndHostCaseButKeepsImplicitPortsDistinct() async throws {
        let root = try Scratch("remote-edit-canonical"), provider = CopyEditProvider()
        let a = URL(string: "sftp://user:password@HOST.invalid/file.txt")!
        let b = URL(string: "sftp://user@host.invalid/file.txt")!
        #expect(RemoteEditSessionStore.identity(a) == RemoteEditSessionStore.identity(b))
        let explicit = URL(string: "sftp://user@host.invalid:22/file.txt")!
        #expect(RemoteEditSessionStore.identity(b) != RemoteEditSessionStore.identity(explicit))
        let one = RemoteEditSessionStore(remote: a, root: root.url)
        let two = RemoteEditSessionStore(remote: b, root: root.url)
        #expect(try await one.open(provider: provider) == two.local)
        #expect(try await two.open(provider: provider) == one.local)
        let data = try Data(contentsOf: one.folder.appendingPathComponent("session.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains("password"))
    }
}
