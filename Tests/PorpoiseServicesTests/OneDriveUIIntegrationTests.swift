import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// DropboxUIIntegrationTests' checks of the shared cloud UI services, for OneDrive against the fake Graph server.
@MainActor private final class OneDriveUIFixture {
    let server: FakeGraphServer
    let defaults: UserDefaults
    let suite = "porpoise-onedrive-ui-" + UUID().uuidString
    let store: OneDriveAccountStore
    let backend: OneDriveCloudBackend
    let composite: CompositeCloudBackend
    let accounts = CloudAccounts()
    init(http: CloudHTTPTransport = .init()) throws {
        Settings.store.set("fixture-client", forKey: "oneDriveClientID")
        server = try FakeGraphServer(); defaults = UserDefaults(suiteName: suite)!
        store = OneDriveAccountStore(
            defaults: defaults, credentials: MemoryCredentials(), configuration: server.config, directory: server.directory, http: http)
        backend = OneDriveCloudBackend(store: store)
        let drive = DemoCloudBackend(); drive.links["not a link"] = .notALink
        composite = CompositeCloudBackend([.oneDrive: backend, .googleDrive: drive]); accounts.backend = composite
        accounts.operations = FileOperationsController()
    }
    func connect() async throws -> CloudAccount {
        try await awaitCallback { continuation in
            _ = accounts.connect(
                .oneDrive, openBrowser: openInFakeBrowser,
                done: { continuation.resume(with: $0.mapError { $0 as Error }) })
        }
    }
    func cleanup() {
        backend.setActive(false)
        for account in store.accounts { RemoteFS.registerCloud(nil, for: OneDriveLocation(accountID: account.id).url) }
        defaults.removePersistentDomain(forName: suite)
    }
}

@Suite(.serialized, .isolatedSettings) struct OneDriveUIIntegrationTests {

    @Test @MainActor func aLateQuotaFromTheReplacedClientCannotPublish() async throws {
        let gate = CloudBackendRequestGate { request in request.url?.query?.contains("select=quota") == true }
        defer { gate.resume() }
        let fixture = try OneDriveUIFixture(http: gate.http); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        await expectEventually { gate.waiting }
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let original = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        fixture.backend.setActive(false); await original.stopFeeds()
        try await fixture.server.configure(["quota": ["used": 900, "total": 2000, "remaining": 1100]])
        let result: Result<Void, CloudConnectError> = try await awaitCallback { callback in
            _ = fixture.accounts.signInAgain(account.id, openBrowser: openInFakeBrowser, done: { callback.resume(returning: $0) })
        }
        try result.get()
        let replacement = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        #expect(replacement.client !== original.client)
        fixture.backend.setActive(false); await replacement.stopFeeds()
        let published = Locked<[Int64]>([]), publish = fixture.backend.onChange
        fixture.backend.onChange = { [weak backend = fixture.backend] in
            if let used = backend?.accounts.first?.quotaUsed { published.append(used) }
            publish?()
        }
        gate.resume()
        await expectEventually {
            fixture.backend.checkForChanges(account.id)
            return fixture.backend.accounts.first?.quotaUsed == 900
        }
        #expect(!published.value.contains(4_000_000_000))
    }

    @Test @MainActor func removalDrainsAFeedBeforeUnregisteringTheProvider() async throws {
        let gate = CloudBackendRequestGate { request in request.url?.path.hasSuffix("/delta") == true }
        defer { gate.resume() }
        let fixture = try OneDriveUIFixture(http: gate.http); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        let marker = provider.client.metadataCache.directory.appendingPathComponent("lifecycle-probe")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("retained until the feed drains".utf8).write(to: marker)
        await expectEventually { gate.waiting }
        let finished = Flag()
        let removing = Task { @MainActor in
            let error: Error? = try await awaitCallback { callback in
                fixture.backend.remove(account.id) { callback.resume(returning: $0) }
            }
            finished.set(); return error
        }
        defer { gate.resume(); removing.cancel() }
        await expectEventually { gate.cancelled.isSet }
        #expect(!finished.isSet && fixture.backend.accounts.count == 1)
        #expect(RemoteFS.provider(for: root) === provider)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        gate.resume()
        #expect(try await removing.value == nil)
        #expect(fixture.backend.accounts.isEmpty && RemoteFS.provider(for: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test @MainActor func reconciliationKeepsProviderUntilSameAccountGetsANewClient() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let original = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        fixture.backend.setActive(false); await original.stopFeeds()
        var changes = 0
        let publish = fixture.backend.onChange
        fixture.backend.onChange = {
            changes += 1; publish?()
        }
        fixture.store.onChange?()
        #expect(RemoteFS.provider(for: root) === original)
        #expect(changes == 1)
        let result: Result<Void, CloudConnectError> = try await awaitCallback { callback in
            _ = fixture.accounts.signInAgain(account.id, openBrowser: openInFakeBrowser, done: { callback.resume(returning: $0) })
        }
        try result.get()
        let replacement = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        #expect(replacement !== original && replacement.client !== original.client)
        #expect(replacement.client === fixture.store.client(for: replacement.client.accountID))
        #expect(fixture.accounts.accounts.map(\.id) == [account.id])
        fixture.backend.setActive(false); await replacement.stopFeeds()
        let notices = Locked<[(String, Bool)]>([])
        let observer = NotificationCenter.default.addObserver(forName: CloudAccounts.remoteChanged, object: nil, queue: nil) { notice in
            if let key = notice.object as? String { notices.append((key, Thread.isMainThread)) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        replacement.client.onFreshness?()
        await expectEventually { notices.value.contains { $0.0 == account.id } }
        #expect(notices.value.filter { $0.0 == account.id }.allSatisfy { $0.1 })
    }

    @Test @MainActor func clientAndStoreCallbacksDoNotRetainBackend() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        _ = try await fixture.connect()
        fixture.backend.setActive(false)
        var temporary: OneDriveCloudBackend? = OneDriveCloudBackend(store: fixture.store)
        let observed = NSHashTable<OneDriveCloudBackend>.weakObjects()
        observed.add(try #require(temporary))
        temporary = nil
        #expect(observed.allObjects.isEmpty)
    }
    @Test @MainActor func quotaFlowsThroughAccountSidebarAndRefreshes() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        await expectEventually { fixture.accounts.accounts.first?.quotaTotal == 5_368_709_120 }
        #expect(fixture.accounts.accounts.first?.quotaUsed == 4_000_000_000)
        let section = try #require(fixture.accounts.sections().first)
        #expect(section.quotaUsed == 4_000_000_000 && section.quotaTotal == 5_368_709_120)
        #expect(section.entries.first?.isVolume == true)
        var changes = 0
        let publish = fixture.backend.onChange
        fixture.backend.onChange = {
            changes += 1; publish?()
        }
        try await fixture.server.configure(["quota": ["used": 900, "total": 2000, "remaining": 1100, "state": "normal"]])
        fixture.backend.checkForChanges(account.id)
        await expectEventually { fixture.accounts.accounts.first?.quotaUsed == 900 }
        #expect(fixture.accounts.accounts.first?.quotaTotal == 2000)
        #expect(fixture.accounts.sections().first?.quotaUsed == 900)
        #expect(changes > 0)
        // Returning to the foreground refreshes quota; a drive without a total (some business libraries) keeps it unknown.
        fixture.backend.setActive(false)
        try await fixture.server.configure(["quota": ["used": 250]])
        fixture.backend.setActive(true)
        await expectEventually { fixture.accounts.accounts.first?.quotaUsed == 250 }
        #expect(fixture.accounts.accounts.first?.quotaTotal == nil)
        #expect(fixture.accounts.sections().first?.entries.first?.isVolume == false)
        let requests = try await fixture.server.requests().filter { ($0["route"] as? String) == "/v1.0/drives/" + FakeGraphServer.drive }
        #expect(requests.count >= 3)
        #expect(requests.allSatisfy { $0["auth"] as? Bool == true })
    }

    @Test @MainActor func descriptorConnectCompositionRootsAndSettingsNavigation() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        #expect(account.provider == .oneDrive && fixture.accounts.accounts.count == 1)
        #expect(fixture.accounts.availableRows(account.id) == [.myDrive, .sharedWithMe])
        #expect(fixture.accounts.sections().first?.entries.map(\.title) == ["My files", "Shared with me"])
        #expect(fixture.accounts.sections().first?.brand == "onedrive")
        #expect(fixture.accounts.rootTitle(.myDrive, for: account.id) == "My files")
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        #expect(PlacesModel.isCloud(root) && RemoteFS.isRemote(root))
        #expect(fixture.composite.accountID(for: root) == account.id)
        let source = try #require(fixture.composite.content(for: root))
        #expect(source.ref(for: root)?.account.hasPrefix("onedrive:") == true)
        #expect(source.offlineDirectory?.path.hasPrefix(fixture.server.directory.path) == true)
        #expect(fixture.accounts.account(for: root)?.id == account.id)
        #expect(fixture.composite.permissions(for: root)?.canAddChildren == true)
        #expect(CloudProviderDescriptor.descriptor(for: root)?.provider == .oneDrive)
        #expect(CloudProvider.oneDrive.descriptor.webLink(URL(string: "https://onedrive.live.com")!, email: account.email).query == nil)
        #expect(
            CloudProvider.googleDrive.descriptor.webLink(URL(string: "https://drive.google.com/drive/my-drive")!, email: account.email).query?
                .contains("authuser=") == true)
        #expect(CloudProvider.googleDrive.descriptor.root(.myDrive).title == "My Drive")
        fixture.accounts.setShows(.sharedWithMe, for: account.id, false)
        #expect(fixture.accounts.sections()[0].entries.count == 1)
        #expect(fixture.composite.info(for: root) == nil)
        #expect(fixture.composite.content(for: "absent") == nil)
        #expect(fixture.composite.savedAt(for: root) == nil)
    }

    @Test @MainActor func pagedBrowserExpansionSnapshotsSearchAndLiveChanges() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        let rows = try await provider.refresh(root); #expect(rows.count == 3)
        #expect(provider.cachedListing(root) == rows)
        #expect(fixture.composite.savedAt(for: root) != nil)
        let folder = try #require(rows.first { $0.isDirectory }); await provider.prefetch([folder.url])
        let model = DirectoryModel(location: root); model.props.mode = .details; model.reload(); model.setExpanded(folder.url, true)
        #expect(model.items == rows && !model.isLoading)
        #expect(model.rows.contains { $0.depth == 1 })
        let file = try #require(rows.first { !$0.isDirectory }); model.selection = [file.url]
        let shared = try #require(fixture.accounts.url(account.id, root: .sharedWithMe))
        #expect(try await provider.refresh(shared).contains { $0.name == "Shared Folder" })
        #expect(fixture.composite.permissions(for: shared)?.canAddChildren == false)
        let page: CloudSearchPage = try await awaitCallback { continuation in
            _ = fixture.composite.search("txt", in: root, everywhere: true, contents: true, pageToken: nil) { continuation.resume(with: $0) }
        }
        #expect(page.items.count == 2 && page.nextPageToken != nil)
        let client = try provider.scoped(root); try await client.changes.check()
        try await fixture.server.configure(["files": [["id": "FIXTURE!live", "name": "live.txt", "text": "arrived"]]])
        try await client.changes.check(); model.reload(keepSelection: true)
        #expect(provider.cachedListing(root)?.contains { $0.name == "live.txt" } == true)
        #expect(model.selection.contains(file.url))
        #expect(RemoteFS.displayName(for: folder.url) == folder.name)
        provider.setActive(false)
    }

    @Test @MainActor func activityCopiesInOutFoldersConflictsAndConditionalReplacement() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        let local = fixture.server.fixture.scratch.url.appendingPathComponent("payload.txt"); try Data("payload".utf8).write(to: local)
        let controller = FileOperationsController()
        let uploaded: [URL] = try await awaitCallback { continuation in
            controller.run(.copy, [local], to: root, window: nil) { continuation.resume(returning: $0) }
        }
        let remote = try #require(uploaded.first)
        #expect(OneDriveLocation(url: remote)?.itemID.hasPrefix("FIXTURE!") == true)
        #expect(remote.lastPathComponent != "payload.txt")
        #expect(controller.activities.last?.state == .completed)
        let output = try fixture.server.fixture.scratch.folder("output")
        let downloaded: [URL] = try await awaitCallback { continuation in
            controller.run(.copy, [remote], to: output, window: nil) { continuation.resume(returning: $0) }
        }
        #expect(downloaded.first?.lastPathComponent == "payload.txt")
        #expect(try Data(contentsOf: output.appendingPathComponent("payload.txt")) == Data("payload".utf8))
        func copy(_ rule: TransferConflictRule) async throws -> RemoteTransferJob {
            let job = RemoteTransferJob(
                kind: .copy, sources: [local], destination: root, control: JobControl(),
                rule: rule, options: .init())
            try await awaitCallback { continuation in
                Thread {
                    job.run(); continuation.resume()
                }.start()
            }; return job
        }
        let both = try await copy(.keepBoth); #expect(both.errors.isEmpty && both.results.count == 1)
        try Data("replacement".utf8).write(to: local)
        let replaced = try await copy(.replace); #expect(replaced.errors.isEmpty && replaced.results == [remote])
        let tree = try fixture.server.fixture.scratch.folder("Tree"); _ = try fixture.server.fixture.scratch.file("Tree/child.txt", "child")
        let treeJob = RemoteTransferJob(
            kind: .copy, sources: [tree], destination: root, control: JobControl(), rule: .ask,
            options: .init())
        try await awaitCallback { continuation in
            Thread {
                treeJob.run(); continuation.resume()
            }.start()
        }
        #expect(treeJob.errors.isEmpty && treeJob.results.count == 1)
        let treeURL = try #require(treeJob.results.first); #expect(try await provider.refresh(treeURL).map(\.name) == ["child.txt"])
        let copiedFolder = try await provider.refresh(root).first { $0.name == "Folder" }!
        let native = RemoteTransferJob(
            kind: .copy, sources: [copiedFolder.url], destination: treeURL,
            control: JobControl(), rule: .ask, options: .init())
        try await awaitCallback { continuation in
            Thread {
                native.run(); continuation.resume()
            }.start()
        }
        #expect(native.errors.isEmpty)
    }

    @Test @MainActor func replacementRejectsARemoteEditAfterConflictChoice() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        let baseline = try #require(provider.transferRevision(file.url))
        let local = try fixture.server.fixture.scratch.file("replacement.txt", "mine")
        try await fixture.server.configure(["files": [["id": "FIXTURE!hello", "name": "hello.txt", "text": "concurrent remote edit"]]])
        let error: Error? = try await awaitCallback { continuation in
            Thread {
                do {
                    _ = try provider.uploadTransfer(
                        local, in: root, named: file.name, replacing: file.url,
                        expectedRevision: baseline, operationID: UUID())
                    continuation.resume(returning: nil)
                } catch { continuation.resume(returning: error) }
            }.start()
        }
        #expect(error as? OneDriveError == .conflict)
        let client = try provider.scoped(root)
        #expect(try await client.metadata("FIXTURE!hello").quickXorHash == OneDriveContentHash.hash(Data("concurrent remote edit".utf8)))
    }

    @Test @MainActor func sharedOfflineStorePinRemoveOpenAndStream() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
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
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        let editing = CloudEditing(); editing.saveDelay = 0.02
        var opened: URL?
        let success: Bool = try await awaitCallback { continuation in
            editing.open(file, using: { opened = $0 }) { continuation.resume(returning: $0) }
        }
        #expect(success)
        let entry = try #require(editing.entries.first); let local = try #require(opened)
        #expect(entry.provider == .oneDrive && entry.detail.contains("OneDrive") && editing.contains(entry.id))
        try Data("local edit".utf8).write(to: local)
        await expectEventually { editing.entries.first?.mark == .saved }
        let client = try provider.scoped(file.url)
        #expect(try await client.metadata(entry.fileID).quickXorHash == OneDriveContentHash.hash(local))
        try await fixture.server.configure(["files": [["id": entry.fileID, "name": "hello.txt", "text": "another writer"]]])
        try Data("mine".utf8).write(to: local)
        await expectEventually { editing.entries.first?.mark == .conflict }
        editing.dismiss(entry.id); #expect(editing.contains(entry.id))
        editing.replace(entry.id)
        await expectEventually { editing.entries.first?.mark == .saved }
        #expect(try await client.metadata(entry.fileID).quickXorHash == OneDriveContentHash.hash(local))
        var launched: [URL] = []; editing.openFile = { launched.append($0) }; editing.openBoth(entry.id)
        await expectEventually { launched.count == 2 }
        editing.keepBoth(entry.id)
        await expectEventually { editing.entries.first?.fileID != entry.fileID }
        #expect(try await client.list().filter { $0.name.hasPrefix("hello") }.count == 2)
        editing.dismiss(entry.id); #expect(editing.entries.isEmpty)
        editing.restore(client)
    }

    @Test @MainActor func recoveredOneDriveEditsRespectLaunchSettingAndRetryOnReconnect() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        let row = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        let client = try provider.scoped(row.url)
        let session = try await client.edits.begin(client.metadata(provider.location(row.url).itemID))
        try Data("saved before quit".utf8).write(to: session.localURL, options: .atomic)
        client.reached(URLError(.notConnectedToInternet))
        let editing = CloudEditCoordinator(); editing.saveDelay = 0.02
        editing.restore(client)
        #expect(editing.entries.isEmpty)
        editing.restoresAtLaunch = true
        await expectEventually { editing.contains(session.id) }
        #expect(editing.entries.first?.mark.needsAttention == true)
        #expect(editing.entry(for: row.url)?.id == session.id)
        client.reached(nil)
        NotificationCenter.default.post(name: CloudAccounts.changed, object: nil)
        await expectEventually { editing.entries.first?.mark == .saved }
        #expect(try await client.metadata(session.file.id).quickXorHash == OneDriveContentHash.hash(session.localURL))
        // The recovered copy is watched too, including successive atomic editor saves.
        try Data("after relaunch".utf8).write(to: session.localURL, options: .atomic)
        await expectEventually {
            (try? OneDriveContentHash.hash(session.localURL)) != session.sentHash && editing.entries.first?.mark == .saved
        }
        await expectEventually { editing.entries.first?.lastSaved != nil }
        let expected = try OneDriveContentHash.hash(session.localURL)
        try await expectEventually { try await client.metadata(session.file.id).quickXorHash == expected }
    }

    @Test @MainActor func failedOneDriveReplacementPostsAndKeepsConflict() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let provider = try #require(RemoteFS.provider(for: root) as? OneDriveProvider)
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        let editing = CloudEditCoordinator(); editing.saveDelay = 0.02
        var messages: [String] = []; editing.post = { text, _ in messages.append(text) }
        editing.open(file)
        await expectEventually { !editing.entries.isEmpty }
        let entry = try #require(editing.entries.first)
        try await fixture.server.configure(["files": [["id": entry.fileID, "name": "hello.txt", "text": "remote"]]])
        try Data("mine".utf8).write(to: entry.localURL)
        await expectEventually { editing.entries.first?.mark == .conflict }
        // Really unreachable: marking the client offline lasted only until a request already under way (the change
        // feed's, after the remote edit) came back and marked it online, and then the replacement went through.
        fixture.server.fixture.stop()
        editing.replaceWithMine(entry.id)
        await expectEventually { messages.contains { $0.hasPrefix("Couldn’t do that") } }
        #expect(editing.entries.first?.mark == .conflict)
        #expect(try Data(contentsOf: entry.localURL) == Data("mine".utf8))
    }

    @Test @MainActor func mutationsUseDescriptorUndoPolicyAndAccountCallbacks() async throws {
        let fixture = try OneDriveUIFixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect(); let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let folder: FileItem = try await awaitCallback { continuation in
            fixture.accounts.createFolder(named: "Created", in: root) { continuation.resume(with: $0) }
        }
        #expect(fixture.accounts.operations.undoStack.isEmpty)
        #expect(!fixture.accounts.supportsTrashUndo([folder.url]))
        #expect(fixture.accounts.deletionTitle(for: folder.url) == "Delete from OneDrive…")
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
        #expect(fixture.accounts.trashMessage(removed, names: [folder.url: "Renamed"]) == "Deleted “Renamed” from OneDrive")
        let failure: Error? = try await awaitCallback { continuation in
            fixture.composite.untrash(removed) { _, error in continuation.resume(returning: error) }
        }
        #expect((failure as? OneDriveError) == .unsupportedUndo)
        let avatar: Data? = try await awaitCallback { continuation in
            fixture.composite.avatar(account.id) { continuation.resume(returning: $0) }
        }
            ;
        #expect(avatar == nil)
        let link: CloudLinkResult = try await awaitCallback { continuation in
            fixture.composite.resolveLink("not a link") { continuation.resume(returning: $0) }
        }
            ;
        #expect(link == .notALink)
        fixture.composite.setActive(false); fixture.composite.checkForChanges(account.id)
    }
}
