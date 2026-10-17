import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Cloud transfers answer name conflicts as local and server copies do.
@Suite(.serialized, .isolatedSettings) struct TransferConflictParityTests {
    private func driveJob(_ source: URL, into folder: URL, rule: TransferConflictRule = .ask) -> RemoteTransferJob {
        RemoteTransferJob(
            kind: .copy, sources: [source], destination: folder,
            control: FileJob(kind: .copy, sources: [source], destinationFolder: folder), rule: rule, options: .init())
    }

    // B6: a Drive shortcut to a folder meeting a folder is no folder pair: never merged into it (as d04b320 for links).
    @Test func aDriveShortcutToAFolderIsNeverMergedIntoAFolder() async throws {
        let tests = DriveMutationTests()
        let server = try tests.server(), scratch = try Scratch()
        let client = try tests.client(server, folder: scratch.url.appendingPathComponent("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let root = DriveLocation(accountID: client.accountID).url
        let listing = try await offThePool { try provider.list(root) }
        let shortcut = try #require(listing.first { $0.name == "Atlas shortcut" })
        #expect(shortcut.isSymlink && shortcut.isDirectory)
        let out = scratch.url.appendingPathComponent("out")
        let existing = out.appendingPathComponent("Atlas shortcut")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: existing.appendingPathComponent("keep.txt"))

        // "Replace" chosen for folders, applied to all: asked again, as a local copy asks.
        let sticky = driveJob(shortcut.url, into: out)
        var asked: [ConflictInfo] = []
        sticky.sticky = .writeInto
        sticky.resolve = { info in
            asked.append(info); return .init(.skip)
        }
        await offThePool { sticky.run() }
        #expect(asked.count == 1 && sticky.errors.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path) == ["keep.txt"])

        // Replace: refused with a reason, nothing merged or removed.
        let replace = driveJob(shortcut.url, into: out, rule: .replace)
        await offThePool { replace.run() }
        #expect(replace.errors.count == 1 && replace.errors.first?.contains("Keep Both") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path) == ["keep.txt"])

    }

    @Test func folderPairsAndReplacementsNeedTheSameKind() throws {
        let folder = FileItem(url: URL(fileURLWithPath: "/a"), name: "a", isDirectory: true)
        let link = FileItem(url: URL(fileURLWithPath: "/b"), name: "b", isDirectory: true, isSymlink: true)
        let file = FileItem(url: URL(fileURLWithPath: "/c"), name: "c", isDirectory: false)
        #expect(RemoteTransferJob.isFolderPair(folder, folder))
        #expect(!RemoteTransferJob.isFolderPair(link, folder) && !RemoteTransferJob.isFolderPair(folder, link))
        #expect(throws: RemoteError.self) { try RemoteTransferJob.checkReplaceable(link, folder) }
        #expect(throws: RemoteError.self) { try RemoteTransferJob.checkReplaceable(file, folder) }
        #expect(throws: RemoteError.self) { try RemoteTransferJob.checkReplaceable(folder, file) }
        try RemoteTransferJob.checkReplaceable(file, file)
    }

    // B13: identical files skipped in Dropbox are counted, as everywhere else.
    @MainActor @Test func dropboxCountsIdenticalFilesItSkips() async throws {
        Settings.store.set("fixture-app", forKey: "dropboxAppKey")
        let server = try FakeDropboxServer(), scratch = try Scratch()
        let suite = "porpoise-conflicts-" + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = DropboxAccountStore(
            defaults: UserDefaults(suiteName: suite)!, credentials: MemoryCredentials(), configuration: server.config, directory: server.directory)
        let backend = DropboxCloudBackend(store: store)
        defer {
            backend.setActive(false)
            for account in store.accounts { RemoteFS.registerCloud(nil, for: DropboxLocation(accountID: account.id).url) }
        }
        let account = try await store.connect(openBrowser: { url in Task { _ = try? await URLSession.shared.data(from: url) } })
        _ = backend.accounts
        let folder = DropboxLocation(accountID: account.id, itemID: "id:folder", namespaceID: account.rootNamespaceID).url
        let local = scratch.url.appendingPathComponent("nested.txt")
        try Data("Nested fixture.".utf8).write(to: local)  // the same bytes as /Folder/nested.txt
        let job = RemoteTransferJob(
            kind: .copy, sources: [local], destination: folder,
            control: FileJob(kind: .copy, sources: [local], destinationFolder: folder), rule: .different, options: .init(method: .content))
        await offThePool { job.run() }
        #expect(job.errors.isEmpty, "\(job.errors)")
        #expect(job.progress.skippedIdenticalItems == 1, "\(job.progress) \(job.results)")
    }
}
