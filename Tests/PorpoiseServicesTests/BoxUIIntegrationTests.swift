import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// OneDriveUIIntegrationTests' checks of the shared cloud UI services, for Box against the fake Box server.
@MainActor private final class BoxUIFixture {
    let server: FakeBoxServer
    let defaults: UserDefaults
    let suite = "porpoise-box-ui-" + UUID().uuidString
    let store: BoxAccountStore
    let backend: BoxCloudBackend
    let composite: CompositeCloudBackend
    let accounts = CloudAccounts()
    init() throws {
        Settings.store.set("fixture-client", forKey: "boxClientID"); Settings.store.set("fixture-secret", forKey: "boxClientSecret")
        server = try FakeBoxServer(); defaults = UserDefaults(suiteName: suite)!
        store = BoxAccountStore(defaults: defaults, credentials: MemoryCredentials(), configuration: server.config, directory: server.directory)
        backend = BoxCloudBackend(store: store)
        let drive = DemoCloudBackend(); drive.links["not a link"] = .notALink
        composite = CompositeCloudBackend([.box: backend, .googleDrive: drive]); accounts.backend = composite
        accounts.operations = FileOperationsController()
    }
    func connect() async throws -> CloudAccount {
        try await awaitCallback { continuation in
            _ = accounts.connect(.box, openBrowser: openInFakeBrowser, done: { continuation.resume(with: $0.mapError { $0 as Error }) })
        }
    }
    func root(_ account: CloudAccount) throws -> (URL, BoxProvider) {
        let root = try #require(accounts.url(account.id, root: .myDrive))
        return (root, try #require(RemoteFS.provider(for: root) as? BoxProvider))
    }
    func cleanup() {
        backend.setActive(false)
        for account in store.accounts { RemoteFS.registerCloud(nil, for: BoxLocation(accountID: account.id).url) }
        defaults.removePersistentDomain(forName: suite)
    }
}

@Suite(.serialized, .isolatedSettings) struct BoxUIIntegrationTests {
    @Test @MainActor func quotaFlowsThroughAccountSidebarAndRefreshes() async throws {
        let fixture = try BoxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        await expectEventually { fixture.accounts.accounts.first?.quotaTotal == 10_737_418_240 }
        #expect(fixture.accounts.accounts.first?.quotaUsed == 4_000_000_000)
        let section = try #require(fixture.accounts.sections().first)
        #expect(section.quotaUsed == 4_000_000_000 && section.entries.first?.isVolume == true)
        try await fixture.server.configure(["quota": ["space_amount": 2000, "space_used": 900]])
        fixture.backend.checkForChanges(account.id)
        await expectEventually { fixture.accounts.accounts.first?.quotaUsed == 900 }
        #expect(fixture.accounts.accounts.first?.quotaTotal == 2000)
        // Returning to the foreground refreshes quota; an unlimited plan has no total.
        fixture.backend.setActive(false)
        try await fixture.server.configure(["quota": ["space_amount": 999_999_999_999_999 as Int64, "space_used": 250]])
        fixture.backend.setActive(true)
        await expectEventually { fixture.accounts.accounts.first?.quotaUsed == 250 }
        #expect(fixture.accounts.accounts.first?.quotaTotal == nil)
        #expect(fixture.accounts.sections().first?.entries.first?.isVolume == false)
        let requests = try await fixture.server.requests().filter { ($0["route"] as? String) == "/2.0/users/me" }
        #expect(requests.count >= 3 && requests.allSatisfy { $0["auth"] as? Bool == true })
    }

    @Test @MainActor func descriptorConnectCompositionRootsAndLinks() async throws {
        let fixture = try BoxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        #expect(account.provider == .box && fixture.accounts.accounts.count == 1 && account.id.hasPrefix("box:"))
        #expect(fixture.accounts.availableRows(account.id) == [.myDrive])
        #expect(fixture.accounts.sections().first?.entries.map(\.title) == ["All Files"])
        #expect(fixture.accounts.sections().first?.brand == "box")
        let (root, provider) = try fixture.root(account)
        #expect(PlacesModel.isCloud(root) && RemoteFS.isRemote(root) && provider.rootTitle(root) == "All Files")
        #expect(fixture.composite.accountID(for: root) == account.id)
        let source = try #require(fixture.composite.content(for: root))
        #expect(source.ref(for: root)?.account.hasPrefix("box:") == true && source.ref(for: root)?.item == "")
        #expect(source.offlineDirectory?.path.hasPrefix(fixture.server.directory.path) == true)
        #expect(fixture.composite.permissions(for: root)?.canAddChildren == true && fixture.composite.permissions(for: root)?.canTrash == false)
        #expect(CloudProviderDescriptor.descriptor(for: root)?.provider == .box)
        #expect(fixture.composite.content(for: "absent") == nil && fixture.composite.savedAt(for: root) == nil)
        // Asked of Box itself: the composite asks its backends in no set order, and the demo Drive one answers any link.
        let link = "https://app.box.com/s/fixturelink"
        try await fixture.server.configure(["links": [link: "11"]])
        let folder: CloudLinkResult = try await awaitCallback { continuation in
            fixture.backend.resolveLink(link) { continuation.resume(returning: $0) }
        }
        let expected = BoxLocation(accountID: try provider.location(root).accountID, itemID: "11", kind: .folder).url
        #expect(folder == .folder(expected), "\(folder)")
        let none: CloudLinkResult = try await awaitCallback { continuation in
            fixture.backend.resolveLink("https://app.box.com/s/unknown") { continuation.resume(returning: $0) }
        }
        #expect(none == .noAccess)
        let notALink: CloudLinkResult = try await awaitCallback { continuation in
            fixture.composite.resolveLink("not a link") { continuation.resume(returning: $0) }
        }
        #expect(notALink == .notALink)
    }

    @Test @MainActor func pagedBrowserExpansionAncestorsSearchAndLiveChanges() async throws {
        let fixture = try BoxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let (root, provider) = try fixture.root(account)
        let rows = try await provider.refresh(root); #expect(rows.count == 4)
        #expect(provider.cachedListing(root) == rows && fixture.composite.savedAt(for: root) != nil)
        let folder = try #require(rows.first { $0.isDirectory }); await provider.prefetch([folder.url])
        let model = DirectoryModel(location: root); model.props.mode = .details; model.reload(); model.setExpanded(folder.url, true)
        #expect(model.items == rows && !model.isLoading)
        #expect(model.rows.contains { $0.depth == 1 })
        let nested = try #require(provider.cachedListing(folder.url)?.first)
        #expect(fixture.composite.ancestors(of: nested.url) == [root, folder.url])
        #expect(fixture.composite.permissions(for: nested.url)?.canRename == true)
        let file = try #require(rows.first { $0.name == "hello.txt" }); model.selection = [file.url]
        let page: CloudSearchPage = try await awaitCallback { continuation in
            _ = fixture.composite.search("txt", in: root, everywhere: true, contents: false, pageToken: nil) { continuation.resume(with: $0) }
        }
        #expect(page.items.count == 2 && page.nextPageToken != nil)
        let inFolder: CloudSearchPage = try await awaitCallback { continuation in
            _ = fixture.composite.search("txt", in: folder.url, everywhere: false, contents: false, pageToken: nil) { continuation.resume(with: $0) }
        }
        #expect(inFolder.items.map(\.name) == ["nested.txt"])
        try await provider.client.changes.check()
        try await fixture.server.configure(["files": [["id": "81", "name": "live.txt", "text": "arrived"]]])
        try await provider.client.changes.check(); model.reload(keepSelection: true)
        #expect(provider.cachedListing(root)?.contains { $0.name == "live.txt" } == true)
        #expect(model.selection.contains(file.url))
        #expect(RemoteFS.displayName(for: folder.url) == folder.name)
        provider.setActive(false)
    }

    @Test @MainActor func activityCopiesInOutFoldersConflictsAndConditionalReplacement() async throws {
        let fixture = try BoxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let (root, provider) = try fixture.root(account)
        let local = fixture.server.fixture.scratch.url.appendingPathComponent("payload.txt"); try Data("payload".utf8).write(to: local)
        let controller = FileOperationsController()
        let uploaded: [URL] = try await awaitCallback { continuation in
            controller.run(.copy, [local], to: root, window: nil) { continuation.resume(returning: $0) }
        }
        let remote = try #require(uploaded.first)
        #expect(BoxLocation(url: remote)?.kind == .file && controller.activities.last?.state == .completed)
        let output = try fixture.server.fixture.scratch.folder("output")
        let downloaded: [URL] = try await awaitCallback { continuation in
            controller.run(.copy, [remote], to: output, window: nil) { continuation.resume(returning: $0) }
        }
        #expect(downloaded.first?.lastPathComponent == "payload.txt")
        #expect(try Data(contentsOf: output.appendingPathComponent("payload.txt")) == Data("payload".utf8))
        func run(_ job: RemoteTransferJob) async throws -> RemoteTransferJob {
            try await awaitCallback { continuation in
                Thread {
                    job.run(); continuation.resume()
                }.start()
            }
            return job
        }
        func copy(_ rule: TransferConflictRule) async throws -> RemoteTransferJob {
            try await run(RemoteTransferJob(kind: .copy, sources: [local], destination: root, control: JobControl(), rule: rule, options: .init()))
        }
        let both = try await copy(.keepBoth); #expect(both.errors.isEmpty && both.results.count == 1)
        try Data("replacement".utf8).write(to: local)
        let replaced = try await copy(.replace); #expect(replaced.errors.isEmpty && replaced.results == [remote])
        let tree = try fixture.server.fixture.scratch.folder("Tree"); _ = try fixture.server.fixture.scratch.file("Tree/child.txt", "child")
        let treeJob = try await run(
            RemoteTransferJob(kind: .copy, sources: [tree], destination: root, control: JobControl(), rule: .ask, options: .init()))
        #expect(treeJob.errors.isEmpty && treeJob.results.count == 1)
        let treeURL = try #require(treeJob.results.first); #expect(try await provider.refresh(treeURL).map(\.name) == ["child.txt"])
        let existing = try #require(try await provider.refresh(root).first { $0.name == "Folder" })
        let native = try await run(
            RemoteTransferJob(kind: .copy, sources: [existing.url], destination: treeURL, control: JobControl(), rule: .ask, options: .init()))
        #expect(native.errors.isEmpty)
        #expect(try await fixture.server.requests().contains { ($0["route"] as? String)?.hasSuffix("/folders/11/copy") == true })
    }

    @Test @MainActor func replacementRejectsARemoteEditAfterConflictChoice() async throws {
        let fixture = try BoxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let (root, provider) = try fixture.root(account)
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        let baseline = try #require(provider.transferRevision(file.url))
        let local = try fixture.server.fixture.scratch.file("replacement.txt", "mine")
        try await fixture.server.configure(["files": [["id": "21", "name": "hello.txt", "text": "concurrent remote edit"]]])
        let error: Error? = try await awaitCallback { continuation in
            Thread {
                do {
                    _ = try provider.uploadTransfer(
                        local, in: root, named: file.name, replacing: file.url, expectedRevision: baseline, operationID: UUID())
                    continuation.resume(returning: nil)
                } catch { continuation.resume(returning: error) }
            }.start()
        }
        #expect(error as? BoxError == .conflict)
        #expect(try await provider.client.metadata("21").sha1 == BoxContentHash.hash(Data("concurrent remote edit".utf8)))
    }

    @Test @MainActor func sharedOfflineStorePinRemoveOpenAndStream() async throws {
        let fixture = try BoxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let (root, provider) = try fixture.root(account)
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        let source = try #require(fixture.composite.content(for: file.url))
        let ref = try #require(source.ref(for: file.url)); let item = try await source.item(ref)
        let store = try CloudOfflineStore(source: source, directory: fixture.server.fixture.scratch.url.appendingPathComponent("offline"))
        _ = try await store.fetch(item, keep: true); #expect(await store.snapshot().isKept(item.ref.item))
        let facade = CloudOffline(accounts: fixture.accounts, root: fixture.server.fixture.scratch.url.appendingPathComponent("facade"))
        facade.operations = FileOperationsController(); facade.activate()
        let kept: Error? = try await awaitCallback { continuation in
            _ = facade.keep(true, [file.url]) { continuation.resume(returning: $0) }
        }
        #expect(kept == nil)
        await expectEventually { facade.usage(account: account.id).kept == item.size }
        #expect(facade.state(for: file.url) == .local)
        let wiped: Error? = try await awaitCallback { continuation in facade.wipe(account: account.id) { continuation.resume(returning: $0) } }
        #expect(wiped == nil && facade.usage(account: account.id).kept == 0)
        let copies = try await provider.client.offlineCopies(); _ = try await copies.fetch(item)
        let playback = try await provider.playback(file.url); #expect(playback.url.isFileURL && playback.stream == nil)
        let operations = FileOperationsController(); provider.openingOperations = operations
        let local = try await provider.preview(file.url); #expect(local == playback.url)
        #expect(operations.activities.isEmpty)
        try await copies.remove([item.ref]); let streamed = try await provider.playback(file.url)
        #expect(streamed.url.host == "127.0.0.1" && streamed.stream != nil); streamed.stream?.stop()
        try await store.remove([item.ref]); #expect(try await store.localCopy(item.ref, revision: item.revision) == nil)
    }

    @Test @MainActor func editWatcherConditionalSaveConflictCopyAndReplace() async throws {
        let fixture = try BoxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let (root, provider) = try fixture.root(account)
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        let editing = CloudEditing(); editing.saveDelay = 0.02
        var opened: URL?
        let success: Bool = try await awaitCallback { continuation in
            editing.open(file, using: { opened = $0 }) { continuation.resume(returning: $0) }
        }
        #expect(success)
        let entry = try #require(editing.entries.first); let local = try #require(opened)
        #expect(entry.provider == .box && entry.detail.contains("Box") && editing.contains(entry.id))
        #expect(editing.entry(for: file.url)?.id == entry.id)
        try Data("local edit".utf8).write(to: local)
        await expectEventually { editing.entries.first?.mark == .saved }
        let client = provider.client
        #expect(try await client.metadata(entry.fileID).sha1 == BoxContentHash.hash(local))
        try await fixture.server.configure(["files": [["id": entry.fileID, "name": "hello.txt", "text": "another writer"]]])
        try Data("mine".utf8).write(to: local)
        await expectEventually { editing.entries.first?.mark == .conflict }
        editing.dismiss(entry.id); #expect(editing.contains(entry.id))
        editing.replace(entry.id)
        await expectEventually { editing.entries.first?.mark == .saved }
        #expect(try await client.metadata(entry.fileID).sha1 == BoxContentHash.hash(local))
        var launched: [URL] = []; editing.openFile = { launched.append($0) }; editing.openBoth(entry.id)
        await expectEventually { launched.count == 2 }
        editing.keepBoth(entry.id)
        await expectEventually { editing.entries.first?.fileID != entry.fileID }
        #expect(try await client.list().filter { $0.name.hasPrefix("hello") }.count == 2)
        editing.dismiss(entry.id); #expect(editing.entries.isEmpty)
        editing.restore(client)
    }

    @Test @MainActor func mutationsMoveToTrashWithUndoThroughBox() async throws {
        let fixture = try BoxUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let (root, _) = try fixture.root(account)
        let folder: FileItem = try await awaitCallback { continuation in
            fixture.accounts.createFolder(named: "Created", in: root) { continuation.resume(with: $0) }
        }
        // Box keeps deleted items in its trash and restores them: deletions are undoable, and say so.
        #expect(fixture.accounts.supportsTrashUndo([folder.url]))
        #expect(fixture.accounts.deletionTitle(for: folder.url) == "Move to Trash")
        #expect(fixture.accounts.operations.undoStack.count == 1)
        let renamed: FileItem = try await awaitCallback { continuation in
            fixture.accounts.rename(folder.url, from: folder.name, to: "Renamed") { continuation.resume(with: $0) }
        }
        #expect(renamed.url == folder.url && renamed.name == "Renamed")
        #expect(fixture.composite.info(for: renamed.url)?.name == "Renamed")
        let removed: [URL] = try await awaitCallback { continuation in
            fixture.accounts.trash([folder.url]) { urls, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: urls) }
            }
        }
        #expect(removed == [folder.url])
        #expect(fixture.accounts.trashMessage(removed, names: [folder.url: "Renamed"]) == "Moved “Renamed” to Box Trash")
        let restored: ([URL], Error?) = try await awaitCallback { continuation in
            fixture.composite.untrash(removed) { urls, error in continuation.resume(returning: (urls, error)) }
        }
        #expect(restored.1 == nil && restored.0 == [folder.url])
        let provider = try #require(RemoteFS.provider(for: root) as? BoxProvider)
        #expect(try await provider.refresh(root).contains { $0.name == "Renamed" && $0.isDirectory })
        // Restoring where the name is taken meanwhile is refused: nothing there is replaced.
        let again: [URL] = try await awaitCallback { continuation in
            fixture.accounts.trash([folder.url]) { urls, _ in continuation.resume(returning: urls) }
        }
        #expect(again == [folder.url])
        _ = try await provider.client.createFolder(name: "Renamed")
        let refused: Error? = try await awaitCallback { continuation in
            fixture.composite.untrash([folder.url]) { _, error in continuation.resume(returning: error) }
        }
        #expect(refused?.localizedDescription.contains("already there") == true)
        let avatar: Data? = try await awaitCallback { continuation in fixture.composite.avatar(account.id) { continuation.resume(returning: $0) } }
        #expect(avatar == nil)
        fixture.composite.setActive(false); fixture.composite.checkForChanges(account.id)
    }
}
