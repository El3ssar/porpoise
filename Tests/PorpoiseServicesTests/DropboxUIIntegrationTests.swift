import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor private final class DropboxUIFixture {
    let server: FakeDropboxServer
    let defaults: UserDefaults
    let suite = "porpoise-dropbox-ui-" + UUID().uuidString
    let store: DropboxAccountStore
    let backend: DropboxCloudBackend
    let composite: CompositeCloudBackend
    let accounts = CloudAccounts()
    init() throws {
        Settings.store.set("fixture-app", forKey: "dropboxAppKey")
        server = try FakeDropboxServer(); defaults = UserDefaults(suiteName: suite)!
        store = DropboxAccountStore(defaults: defaults, credentials: MemoryCredentials(), configuration: server.config, directory: server.directory)
        backend = DropboxCloudBackend(store: store)
        let drive = DemoCloudBackend(); drive.links["not a link"] = .notALink
        composite = CompositeCloudBackend([.dropbox: backend, .googleDrive: drive]); accounts.backend = composite
        accounts.operations = FileOperationsController()
    }
    func connect() async throws -> CloudAccount {
        try await withCheckedThrowingContinuation { continuation in
            _ = accounts.connect(
                .dropbox, openBrowser: { url in Task { _ = try? await URLSession.shared.data(from: url) } },
                done: { continuation.resume(with: $0.mapError { $0 as Error }) })
        }
    }
    func cleanup() {
        backend.setActive(false)
        for account in store.accounts { RemoteFS.registerCloud(nil, for: DropboxLocation(accountID: account.id).url) }
        defaults.removePersistentDomain(forName: suite)
    }
}

@Suite(.serialized, .isolatedSettings) struct DropboxUIIntegrationTests {
    @Test @MainActor func descriptorConnectCompositionRootsAndSettingsNavigation() async throws {
        let fixture = try DropboxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        #expect(account.provider == .dropbox && fixture.accounts.accounts.count == 1)
        #expect(fixture.accounts.availableRows(account.id) == [.myDrive, .sharedWithMe, .sharedDrives])
        #expect(fixture.accounts.sections().first?.entries.map(\.title) == ["Files", "Shared with me", "Team space"])
        #expect(fixture.accounts.sections().first?.brand == "dropbox")
        #expect(fixture.accounts.rootTitle(.myDrive, for: account.id) == "Files")
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        #expect(PlacesModel.isCloud(root) && RemoteFS.isRemote(root))
        #expect(fixture.composite.accountID(for: root) == account.id)
        let source = try #require(fixture.composite.content(for: root))
        #expect(source.ref(for: root)?.account.hasPrefix("dropbox:") == true)
        #expect(source.offlineDirectory?.path.hasPrefix(fixture.server.directory.path) == true)
        #expect(fixture.accounts.account(for: root) == account)
        #expect(fixture.composite.permissions(for: root)?.canAddChildren == true)
        #expect(CloudProviderDescriptor.descriptor(for: root)?.provider == .dropbox)
        #expect(CloudProvider.dropbox.descriptor.webLink(URL(string: "https://www.dropbox.com/home")!, email: account.email).query == nil)
        #expect(
            CloudProvider.googleDrive.descriptor.webLink(URL(string: "https://drive.google.com/drive/my-drive")!, email: account.email).query?
                .contains("authuser=") == true)
        #expect(CloudProvider.googleDrive.descriptor.root(.myDrive).title == "My Drive")
        fixture.accounts.setShows(.sharedWithMe, for: account.id, false)
        #expect(fixture.accounts.sections()[0].entries.count == 2)
        #expect(fixture.composite.info(for: root) == nil)
        #expect(fixture.composite.content(for: "absent") == nil)
        #expect(fixture.composite.savedAt(for: root) == nil)
    }

    @Test @MainActor func pagedBrowserExpansionSnapshotsSearchAndLiveChanges() async throws {
        let fixture = try DropboxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? DropboxProvider)
        let rows = try await provider.refresh(root); #expect(rows.count == 3)
        #expect(provider.cachedListing(root) == rows)
        #expect(fixture.composite.savedAt(for: root) != nil)
        let folder = try #require(rows.first { $0.isDirectory }); await provider.prefetch([folder.url])
        let model = DirectoryModel(location: root); model.props.mode = .details; model.reload(); model.setExpanded(folder.url, true)
        #expect(model.items == rows && !model.isLoading)
        #expect(model.rows.contains { $0.depth == 1 })
        let file = try #require(rows.first { !$0.isDirectory }); model.selection = [file.url]
        let shared = try #require(fixture.accounts.url(account.id, root: .sharedWithMe))
        #expect(try await provider.refresh(shared).contains { $0.name == "Unmounted shared folder" })
        #expect(fixture.composite.permissions(for: shared)?.canAddChildren == false)
        let page: CloudSearchPage = try await withCheckedThrowingContinuation { continuation in
            _ = fixture.composite.search("txt", in: root, everywhere: true, contents: true, pageToken: nil) { continuation.resume(with: $0) }
        }
        #expect(page.items.count == 2 && page.nextPageToken != nil)
        let client = try provider.scoped(root); try await client.changes.check()
        try await fixture.server.configure(["files": [["id": "id:live", "path": "/live.txt", "text": "arrived"]]])
        try await client.changes.check(); model.reload(keepSelection: true)
        #expect(provider.cachedListing(root)?.contains { $0.name == "live.txt" } == true)
        #expect(model.selection.contains(file.url))
        #expect(RemoteFS.displayName(for: folder.url) == folder.name)
        provider.setActive(false)
    }

    @Test @MainActor func activityCopiesInOutFoldersConflictsAndConditionalReplacement() async throws {
        let fixture = try DropboxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? DropboxProvider)
        let local = fixture.server.fixture.scratch.url.appendingPathComponent("payload.txt"); try Data("payload".utf8).write(to: local)
        let controller = FileOperationsController()
        let uploaded: [URL] = await withCheckedContinuation { continuation in
            controller.run(.copy, [local], to: root, window: nil) { continuation.resume(returning: $0) }
        }
        let remote = try #require(uploaded.first)
        #expect(DropboxLocation(url: remote)?.itemID.hasPrefix("id:") == true)
        #expect(remote.lastPathComponent != "payload.txt")
        #expect(controller.activities.last?.state == .completed)
        let output = try fixture.server.fixture.scratch.folder("output")
        let downloaded: [URL] = await withCheckedContinuation { continuation in
            controller.run(.copy, [remote], to: output, window: nil) { continuation.resume(returning: $0) }
        }
        #expect(downloaded.first?.lastPathComponent == "payload.txt")
        #expect(try Data(contentsOf: output.appendingPathComponent("payload.txt")) == Data("payload".utf8))
        func copy(_ rule: TransferConflictRule) async -> RemoteTransferJob {
            let job = RemoteTransferJob(
                kind: .copy, sources: [local], destination: root, control: FileJob(kind: .copy, sources: [local], destinationFolder: root),
                rule: rule, options: .init())
            await withCheckedContinuation { continuation in
                Thread {
                    job.run(); continuation.resume()
                }.start()
            }; return job
        }
        let both = await copy(.keepBoth); #expect(both.errors.isEmpty && both.results.count == 1)
        try Data("replacement".utf8).write(to: local)
        let replaced = await copy(.replace); #expect(replaced.errors.isEmpty && replaced.results == [remote])
        let tree = try fixture.server.fixture.scratch.folder("Tree"); _ = try fixture.server.fixture.scratch.file("Tree/child.txt", "child")
        let treeJob = RemoteTransferJob(
            kind: .copy, sources: [tree], destination: root, control: FileJob(kind: .copy, sources: [tree], destinationFolder: root), rule: .ask,
            options: .init())
        await withCheckedContinuation { continuation in
            Thread {
                treeJob.run(); continuation.resume()
            }.start()
        }
        #expect(treeJob.errors.isEmpty && treeJob.results.count == 1)
        let treeURL = try #require(treeJob.results.first); #expect(try await provider.refresh(treeURL).map(\.name) == ["child.txt"])
        let copiedFolder = try await provider.refresh(root).first { $0.name == "Folder" }!
        let native = RemoteTransferJob(
            kind: .copy, sources: [copiedFolder.url], destination: treeURL,
            control: FileJob(kind: .copy, sources: [copiedFolder.url], destinationFolder: treeURL), rule: .ask, options: .init())
        await withCheckedContinuation { continuation in
            Thread {
                native.run(); continuation.resume()
            }.start()
        }
        #expect(native.errors.isEmpty)
    }

    @Test @MainActor func replacementRejectsARemoteEditAfterConflictChoice() async throws {
        let fixture = try DropboxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? DropboxProvider)
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        let baseline = try #require(provider.transferRevision(file.url))
        let local = try fixture.server.fixture.scratch.file("replacement.txt", "mine")
        try await fixture.server.configure(["files": [["id": "id:hello", "path": "/hello.txt", "text": "concurrent remote edit"]]])
        let error: Error? = await withCheckedContinuation { continuation in
            Thread {
                do {
                    _ = try provider.uploadTransfer(
                        local, in: root, named: file.name, replacing: file.url,
                        expectedRevision: baseline, operationID: UUID())
                    continuation.resume(returning: nil)
                } catch { continuation.resume(returning: error) }
            }.start()
        }
        #expect(error as? DropboxError == .conflict)
        let client = try provider.scoped(root)
        #expect(try await client.metadata("id:hello").contentHash == DropboxContentHash.hash(Data("concurrent remote edit".utf8)))
    }

    @Test @MainActor func sharedOfflineStorePinRemoveOpenAndStream() async throws {
        let fixture = try DropboxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? DropboxProvider)
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        let source = try #require(fixture.composite.content(for: file.url))
        let ref = try #require(source.ref(for: file.url)); let item = try await source.item(ref)
        let store = try CloudOfflineStore(source: source, directory: fixture.server.fixture.scratch.url.appendingPathComponent("offline"))
        _ = try await store.fetch(item, keep: true); #expect(await store.snapshot().isKept(item.ref.item))
        let facade = CloudOffline(accounts: fixture.accounts, root: fixture.server.fixture.scratch.url.appendingPathComponent("facade"))
        facade.operations = FileOperationsController(); facade.activate()
        let kept: Error? = await withCheckedContinuation { continuation in
            _ = facade.keep(true, [file.url]) { continuation.resume(returning: $0) }
        }
        #expect(kept == nil)
        try await uiEventually { facade.usage(account: account.id).kept == item.size }
        #expect(facade.state(for: file.url) == .kept)
        let wiped: Error? = await withCheckedContinuation { continuation in facade.wipe(account: account.id) { continuation.resume(returning: $0) } }
        #expect(wiped == nil && facade.usage(account: account.id).kept == 0)
        let copies = try await provider.scoped(file.url).offlineCopies(); _ = try await copies.fetch(item)
        let playback = try await provider.playback(file.url); #expect(playback.url.isFileURL && playback.stream == nil)
        let operations = FileOperationsController(); provider.openingOperations = operations
        let local = try await provider.preview(file.url); #expect(local == playback.url)
        #expect(operations.activities.isEmpty)
        try await copies.remove([item.ref]); let streamed = try await provider.playback(file.url)
        #expect(streamed.url.host == "127.0.0.1" && streamed.stream != nil); streamed.stream?.stop()
        try await store.remove([item.ref]); #expect(try await store.localCopy(item.ref, revision: item.revision) == nil)
    }

    @Test @MainActor func editWatcherConditionalSaveConflictCopyAndReplace() async throws {
        let fixture = try DropboxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? DropboxProvider)
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        let editing = DropboxEditing(); editing.saveDelay = 0.02
        var opened: URL?
        let success: Bool = await withCheckedContinuation { continuation in
            editing.open(file, using: { opened = $0 }) { continuation.resume(returning: $0) }
        }
        #expect(success)
        let entry = try #require(editing.entries.first); let local = try #require(opened)
        #expect(entry.provider == .dropbox && entry.detail.contains("Dropbox") && editing.contains(entry.id))
        try Data("local edit".utf8).write(to: local)
        try await uiEventually { editing.entries.first?.mark == .saved }
        let client = try provider.scoped(file.url)
        #expect(try await client.metadata(entry.fileID).contentHash == DropboxContentHash.hash(local))
        try await fixture.server.configure(["files": [["id": entry.fileID, "path": "/hello.txt", "text": "another writer"]]])
        try Data("mine".utf8).write(to: local)
        try await uiEventually { editing.entries.first?.mark == .conflict }
        editing.dismiss(entry.id); #expect(editing.contains(entry.id))
        editing.replace(entry.id)
        try await uiEventually { editing.entries.first?.mark == .saved }
        #expect(try await client.metadata(entry.fileID).contentHash == DropboxContentHash.hash(local))
        var launched: [URL] = []; editing.openFile = { launched.append($0) }; editing.openBoth(entry.id)
        try await uiEventually { launched.count == 2 }
        editing.keepBoth(entry.id)
        try await uiEventually { editing.entries.first?.fileID != entry.fileID }
        #expect(try await client.list().filter { $0.name.hasPrefix("hello") }.count == 2)
        editing.dismiss(entry.id); #expect(editing.entries.isEmpty)
        editing.restore(client)
    }

    @Test @MainActor func mutationsUseDescriptorUndoPolicyAndAccountCallbacks() async throws {
        let fixture = try DropboxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let folder: FileItem = try await withCheckedThrowingContinuation { continuation in
            fixture.accounts.createFolder(named: "Created", in: root) { continuation.resume(with: $0) }
        }
        #expect(fixture.accounts.operations.undoStack.isEmpty)
        #expect(!fixture.accounts.supportsTrashUndo([folder.url]))
        #expect(fixture.accounts.deletionTitle(for: folder.url) == "Delete from Dropbox…")
        let renamed: FileItem = try await withCheckedThrowingContinuation { continuation in
            fixture.accounts.rename(folder.url, from: folder.name, to: "Renamed") { continuation.resume(with: $0) }
        }
        #expect(renamed.url == folder.url && renamed.name == "Renamed")
        #expect(fixture.composite.info(for: renamed.url)?.name == "Renamed")
        let removed: [URL] = try await withCheckedThrowingContinuation { continuation in
            fixture.accounts.trash([folder.url]) { urls, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: urls) }
            }
        }
        #expect(removed == [folder.url])
        #expect(fixture.accounts.trashMessage(removed, names: [folder.url: "Renamed"]) == "Deleted “Renamed” from Dropbox")
        let failure: Error? = await withCheckedContinuation { continuation in
            fixture.composite.untrash(removed) { _, error in continuation.resume(returning: error) }
        }
        #expect((failure as? DropboxError) == .unsupportedUndo)
        let avatar: Data? = await withCheckedContinuation { continuation in
            fixture.composite.avatar(account.id) { continuation.resume(returning: $0) }
        }
            ;
        #expect(avatar == nil)
        let link: CloudLinkResult = await withCheckedContinuation { continuation in
            fixture.composite.resolveLink("not a link") { continuation.resume(returning: $0) }
        }
            ;
        #expect(link == .notALink)
        fixture.composite.setActive(false); fixture.composite.checkForChanges(account.id)
    }
}

@MainActor private func uiEventually(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(predicate())
}
