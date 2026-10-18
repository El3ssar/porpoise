import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Cloud transfers answer name conflicts as local and server copies do.
@Suite(.serialized, .isolatedSettings) struct TransferConflictParityTests {
    private func driveJob(_ source: URL, into folder: URL, rule: TransferConflictRule = .ask) -> RemoteTransferJob {
        RemoteTransferJob(
            kind: .copy, sources: [source], destination: folder,
            control: JobControl(), rule: rule, options: .init())
    }

    /// Each engine gets the same conflict cases, checking bytes and identity rather than only policy outputs.
    static func exerciseRules(source: FileItem, bytes: Data, scratch: Scratch, local: Bool = false) async throws {
        for rule in TransferConflictRule.allCases {
            let out = try scratch.folder(rule.rawValue)
            let destination = out.appendingPathComponent(source.name)
            try Data("x".utf8).write(to: destination)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: destination.path)
            let before = JobJournal.Fingerprint(destination)
            var asked = 0
            let control = FileJob(kind: .copy, sources: [source.url], destinationFolder: out)
            if local {
                control.conflictRule = rule
                control.resolveConflict = { _ in
                    asked += 1; return .init(.overwrite)
                }
                _ = try await offThePool { try control.run() }
                #expect(control.errors.isEmpty)
            } else {
                let job = RemoteTransferJob(
                    kind: .copy, sources: [source.url], destination: out, control: control.control, rule: rule, options: .init())
                job.resolve = { _ in
                    asked += 1; return .init(.overwrite)
                }
                await offThePool { job.run() }
                #expect(job.errors.isEmpty, "\(rule): \(job.errors)")
            }
            #expect(asked == (rule == .ask ? 1 : 0))
            if rule == .skip || rule == .keepBoth {
                #expect(try Data(contentsOf: destination) == Data("x".utf8))
                #expect(JobJournal.Fingerprint(destination) == before)
                if rule == .keepBoth {
                    let copy = out.appendingPathComponent(FileFormat.suggestedName(for: source.name, existing: [source.name]))
                    #expect(try Data(contentsOf: copy) == bytes)
                }
            } else {
                #expect(try Data(contentsOf: destination) == bytes, "\(rule)")
            }
        }
    }

    @Test func localAndDriveRunTheSameConflictCases() async throws {
        let tests = DriveMutationTests(), scratch = try Scratch()
        let server = try tests.server()
        let client = try tests.client(server, folder: scratch.path("journal"))
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let listing = try await offThePool { try provider.list(DriveLocation(accountID: client.accountID).url) }
        let source = try #require(listing.first { $0.url.path.hasSuffix("/binary-a") })
        let local = try await offThePool { try provider.download(source.url, into: scratch.folder("download")) }
        let bytes = try Data(contentsOf: local)
        try await Self.exerciseRules(source: source, bytes: bytes, scratch: Scratch())
        try await Self.exerciseRules(source: #require(FileItem.load(local)), bytes: bytes, scratch: Scratch(), local: true)
    }

    @MainActor @Test func dropboxRunsTheSameConflictCases() async throws {
        Settings.store.set("fixture-app", forKey: "dropboxAppKey")
        let server = try FakeDropboxServer(), scratch = try Scratch()
        let suite = "porpoise-rule-" + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = DropboxAccountStore(
            defaults: UserDefaults(suiteName: suite)!, credentials: MemoryCredentials(), configuration: server.config,
            directory: server.directory)
        let backend = DropboxCloudBackend(store: store)
        defer {
            backend.setActive(false)
            for account in store.accounts { RemoteFS.registerCloud(nil, for: DropboxLocation(accountID: account.id).url) }
        }
        let account = try await store.connect(openBrowser: openInFakeBrowser)
        _ = backend.accounts
        let folder = DropboxLocation(accountID: account.id, itemID: "id:folder", namespaceID: account.rootNamespaceID).url
        let provider = try #require(RemoteFS.provider(for: folder))
        let source = try #require(try await offThePool { try provider.list(folder).first { $0.name == "nested.txt" } })
        try await Self.exerciseRules(source: source, bytes: Data("Nested fixture.".utf8), scratch: scratch)
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
        #expect(ConflictPolicy(source: folder, destination: folder).isFolderPair)
        #expect(!ConflictPolicy(source: link, destination: folder).isFolderPair && !ConflictPolicy(source: folder, destination: link).isFolderPair)
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
        let account = try await store.connect(openBrowser: openInFakeBrowser)
        _ = backend.accounts
        let folder = DropboxLocation(accountID: account.id, itemID: "id:folder", namespaceID: account.rootNamespaceID).url
        let local = scratch.url.appendingPathComponent("nested.txt")
        try Data("Nested fixture.".utf8).write(to: local)  // the same bytes as /Folder/nested.txt
        let job = RemoteTransferJob(
            kind: .copy, sources: [local], destination: folder,
            control: JobControl(), rule: .different, options: .init(method: .content))
        await offThePool { job.run() }
        #expect(job.errors.isEmpty, "\(job.errors)")
        #expect(job.progress.skippedIdenticalItems == 1, "\(job.progress) \(job.results)")
    }

    @MainActor private func oneDriveFolder() async throws -> (URL, () -> Void) {
        Settings.store.set("fixture-client", forKey: "oneDriveClientID")
        let fixture = try OneDriveParityTests.Fixture()
        let account = try await fixture.store.connect(openBrowser: openInFakeBrowser)
        _ = fixture.backend.accounts
        let folder = OneDriveLocation(accountID: account.id, itemID: "FIXTURE!folder", driveID: account.driveID).url
        return (
            folder,
            {
                fixture.cleanup(); _ = fixture.server
            }
        )
    }

    @MainActor @Test func oneDriveRunsTheSameConflictCases() async throws {
        let (folder, cleanup) = try await oneDriveFolder(); defer { cleanup() }
        let provider = try #require(RemoteFS.provider(for: folder))
        let source = try #require(try await offThePool { try provider.list(folder).first { $0.name == "nested.txt" } })
        try await Self.exerciseRules(source: source, bytes: Data("Nested fixture.".utf8), scratch: Scratch())
    }

    // Identical files skipped in OneDrive are counted, as everywhere else.
    @MainActor @Test func oneDriveCountsIdenticalFilesItSkips() async throws {
        let (folder, cleanup) = try await oneDriveFolder(); defer { cleanup() }
        let scratch = try Scratch(), local = scratch.url.appendingPathComponent("nested.txt")
        try Data("Nested fixture.".utf8).write(to: local)
        let job = RemoteTransferJob(
            kind: .copy, sources: [local], destination: folder, control: JobControl(), rule: .different, options: .init(method: .content))
        await offThePool { job.run() }
        #expect(job.errors.isEmpty, "\(job.errors)")
        #expect(job.progress.skippedIdenticalItems == 1, "\(job.progress) \(job.results)")
    }
}
