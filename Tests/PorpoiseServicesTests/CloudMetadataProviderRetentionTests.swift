import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.serialized) struct CloudMetadataProviderRetentionTests {
    private func durableEdit<Engine: CloudEditEngine>(
        _ store: CloudEditSessionStore<Engine>, file: Engine.File, cache: CloudMetadataCache<Engine.File>,
        removeOffline: () async throws -> Void, reopen: () throws -> CloudMetadataCache<Engine.File>
    ) async throws where Engine.File: CloudMetadataItem {
        let session = try await store.openSession(file)
        try await removeOffline()
        cache.setRetentionLimits(.init(files: 0, listings: 0, bytes: 0))
        await cache.settleRetention()
        #expect(cache.file(file.id) != nil)
        await store.releaseCopy(session.id)
        await cache.settleRetention()
        #expect(cache.file(file.id) != nil && FileManager.default.fileExists(atPath: session.localURL.path))
        // The durable record must seed metadata even when the disposable metadata file is absent on restart.
        await offThePool { cache.clear() }
        let restored = try reopen()
        restored.setRetentionLimits(.init(files: 0, listings: 0, bytes: 0))
        await restored.settleRetention()
        #expect(restored.file(file.id) != nil && restored.retentionRestoreFailures == 0)
    }

    @Test func allFourEditEnginesRetainCleanDurableSessionsAfterMetadataLoss() async throws {
        let box = try FakeBoxServer(), boxClient = try box.client()
        try await durableEdit(boxClient.edits, file: boxClient.metadata("21"), cache: boxClient.metadataCache) {
            try await boxClient.offlineCopies().wipe()
        } reopen: {
            try box.client(id: boxClient.accountID).metadataCache
        }

        let dropbox = try FakeDropboxServer(), dropboxClient = try dropbox.client()
        try await durableEdit(dropboxClient.edits, file: dropboxClient.metadata("id:hello"), cache: dropboxClient.metadataCache) {
            try await dropboxClient.offlineCopies().wipe()
        } reopen: {
            try dropbox.client(id: dropboxClient.accountID).metadataCache
        }

        let graph = try FakeGraphServer(), oneDrive = try graph.client()
        try await durableEdit(oneDrive.edits, file: oneDrive.metadata("FIXTURE!hello"), cache: oneDrive.metadataCache) {
            try await oneDrive.offlineCopies().wipe()
        } reopen: {
            try graph.client(id: oneDrive.accountID).metadataCache
        }

        let drive = try FakeDriveServer(fixture: FakeDriveServer.fixture("mutations.json")), scratch = try Scratch()
        let account = UUID(), (_, tokens, _) = try drive.client(id: account)
        let client = DriveClient(
            accountID: account, tokens: tokens, baseURL: drive.base.appendingPathComponent("drive/v3/"),
            metadataDirectory: scratch.url)
        try await durableEdit(client.edits, file: client.file("binary-a"), cache: client.metadataCache.storage) {
            try await client.offlineCopies().wipe()
        } reopen: {
            DriveClient(
                accountID: account, tokens: tokens, baseURL: drive.base.appendingPathComponent("drive/v3/"),
                metadataDirectory: scratch.url
            ).metadataCache.storage
        }
    }

    @Test(.isolatedSettings) @MainActor func directoryModelOwnsExpandedListingsUntilCollapse() async throws {
        let server = try FakeBoxServer(), client = try server.client(), provider = BoxProvider(client: client)

        let root = BoxLocation(accountID: client.accountID).url
        let rows = try await provider.refresh(root)
        let folder = try #require(rows.first { $0.isDirectory })
        let children = try await provider.refresh(folder.url)
        RemoteFS.registerCloud(provider, for: root)
        defer { RemoteFS.registerCloud(nil, for: root) }
        let model = DirectoryModel(location: root, prefetchFolders: false)
        model.props.mode = .details
        model.reload()
        model.setExpanded(folder.url, true)
        client.metadataCache.setRetentionLimits(.init(files: 0, listings: 0, bytes: 0))
        #expect(await eventually { !model.isLoading && !model.isRefreshing })
        await client.metadataCache.settleRetention()
        #expect(provider.cachedListing(root) == rows && provider.cachedListing(folder.url) == children)
        #expect(model.rows.contains { $0.depth == 1 })
        model.setExpanded(folder.url, false)
        await client.metadataCache.settleRetention()
        #expect(provider.cachedListing(root) == rows && provider.cachedListing(folder.url) == nil)
        withExtendedLifetime(model) {}
    }

    /// Real provider paging/cache fallback, with zero ordinary allowance: only active owners may survive.
    @MainActor private func browse<Item: CloudMetadataItem>(
        _ provider: any CloudFileProvider, cache: CloudMetadataCache<Item>, root: URL, content: CloudContentSource,
        offline: () throws -> (any CloudFileProvider, CloudMetadataCache<Item>)
    ) async throws {
        cache.setRetentionLimits(.init(files: 0, listings: 0, bytes: 0))
        var source: CloudSource? = CloudSource(location: root, provider: provider)
        source?.retainMetadata(for: [root])
        let rows = try await provider.refresh(root)
        #expect(!rows.isEmpty)
        source?.retainMetadata(for: [root])
        let folder = try #require(rows.first { $0.isDirectory })
        source?.retainMetadata(for: [root, folder.url])
        let children = try await provider.refresh(folder.url)
        source?.retainMetadata(for: [root, folder.url])
        await cache.settleRetention()
        #expect(provider.cachedListing(root) == rows && provider.cachedListing(folder.url) == children)
        source?.retainMetadata(for: [root])
        await cache.settleRetention()
        #expect(provider.cachedListing(folder.url) == nil && provider.cachedListing(root) == rows)
        // A revisit fetches the complete answer after eviction, rather than a successful truncated cache entry.
        source?.retainMetadata(for: [root, folder.url])
        #expect(try await provider.refresh(folder.url) == children)
        let copies = try CloudOfflineStore(source: content, directory: CloudMetadataOwnership.offlineDirectory(for: content))
        let pin = try #require(content.ref(for: folder.url))
        try await copies.pin([pin])
        source?.retainMetadata(for: [root])
        await cache.settleRetention()
        #expect(provider.cachedListing(folder.url) == children)
        try await copies.unpin([pin])
        await cache.settleRetention()
        #expect(provider.cachedListing(folder.url) == nil)
        await offThePool { cache.flush() }
        let (down, restored) = try offline()
        let offlineSource = CloudSource(location: root, provider: down)
        offlineSource.retainMetadata(for: [root])
        restored.setRetentionLimits(.init(files: 0, listings: 0, bytes: 0))
        await restored.settleRetention()
        #expect(try await down.refresh(root) == rows)
        #expect(down.cachedListing(folder.url) == nil)
        await #expect(throws: (any Error).self) { try await down.refresh(folder.url) }
        withExtendedLifetime(offlineSource) {}
        source = nil
        await cache.settleRetention()
        #expect(provider.cachedListing(root) == nil && provider.cachedListing(folder.url) == nil)
        #expect(cache.retentionAccounting?.ordinaryFiles == 0 && cache.retentionAccounting?.ordinaryListings == 0)
    }

    @Test @MainActor func boxEvictOnlineRevisitAndOfflineFallback() async throws {
        let server = try FakeBoxServer(), client = try server.client()

        try await browse(
            BoxProvider(client: client), cache: client.metadataCache, root: BoxLocation(accountID: client.accountID).url,
            content: client.contentSource
        ) {
            let down = BoxClient(
                accountID: client.accountID, configuration: server.config, tokens: client.tokens, directory: server.directory,
                http: .init(send: { _ in throw URLError(.notConnectedToInternet) }))

            return (BoxProvider(client: down), down.metadataCache)
        }
    }

    @Test @MainActor func boxRootPinUsesTheAPIRootBeforeAndAfterRestart() async throws {
        let server = try FakeBoxServer(), client = try server.client(), provider = BoxProvider(client: client)
        let root = BoxLocation(accountID: client.accountID).url
        let rows = try await provider.refresh(root)
        let folder = try #require(rows.first { $0.isDirectory })
        let children = try await provider.refresh(folder.url)
        #expect(client.metadataCache.file(BoxItem.rootID) == nil)
        let source = client.contentSource, rootRef = try #require(client.contentSource.ref(for: root))
        #expect(rootRef.item.isEmpty)
        let copies = try CloudOfflineStore(source: source, directory: CloudMetadataOwnership.offlineDirectory(for: source))
        try await copies.pin([rootRef])
        client.metadataCache.setRetentionLimits(.init(files: 0, listings: 0, bytes: 0))
        await client.metadataCache.settleRetention()
        #expect(provider.cachedListing(root) == rows && provider.cachedListing(folder.url) == children)
        await offThePool { client.metadataCache.flush() }
        let down = BoxClient(
            accountID: client.accountID, configuration: server.config, tokens: client.tokens, directory: server.directory,
            http: .init(send: { _ in throw URLError(.notConnectedToInternet) }))
        down.metadataCache.setRetentionLimits(.init(files: 0, listings: 0, bytes: 0))
        await down.metadataCache.settleRetention()
        let restored = BoxProvider(client: down)
        #expect(restored.cachedListing(root) == rows && restored.cachedListing(folder.url) == children)
        let restoredCopies = try CloudOfflineStore(
            source: down.contentSource, directory: CloudMetadataOwnership.offlineDirectory(for: down.contentSource))
        try await restoredCopies.unpin([rootRef])
        await down.metadataCache.settleRetention()
        #expect(restored.cachedListing(root) == nil && restored.cachedListing(folder.url) == nil)
    }

    @Test @MainActor func dropboxEvictOnlineRevisitAndOfflineFallback() async throws {
        let server = try FakeDropboxServer(), client = try server.client()

        try await browse(
            DropboxProvider(client: client), cache: client.metadataCache, root: DropboxLocation(accountID: client.accountID).url,
            content: client.contentSource
        ) {
            let down = DropboxClient(
                accountID: client.accountID, configuration: server.config, tokens: client.tokens, directory: server.directory,
                http: .init(send: { _ in throw URLError(.notConnectedToInternet) }))

            return (DropboxProvider(client: down), down.metadataCache)
        }
    }

    @Test @MainActor func oneDriveEvictOnlineRevisitAndOfflineFallback() async throws {
        let server = try FakeGraphServer(), client = try server.client()

        try await browse(
            OneDriveProvider(client: client), cache: client.metadataCache, root: OneDriveLocation(accountID: client.accountID).url,
            content: client.contentSource
        ) {
            let down = OneDriveClient(
                accountID: client.accountID, configuration: server.config, tokens: client.tokens, driveID: client.driveID,
                directory: server.directory, http: .init(send: { _ in throw URLError(.notConnectedToInternet) }))

            return (OneDriveProvider(client: down), down.metadataCache)
        }
    }

    @Test @MainActor func driveEvictOnlineRevisitAndOfflineFallback() async throws {
        let server = try FakeDriveServer(), scratch = try Scratch()
        let account = UUID()
        let (_, tokens, _) = try server.client(id: account)
        let client = DriveClient(
            accountID: account, tokens: tokens, baseURL: server.base.appendingPathComponent("drive/v3/"),
            metadataDirectory: scratch.url)

        let root = DriveLocation(accountID: client.accountID).url
        try await browse(
            DriveProvider(accountID: client.accountID, client: client), cache: client.metadataCache.storage, root: root, content: client.contentSource
        ) {
            let down = DriveClient(
                accountID: client.accountID, tokens: tokens, http: .init(send: { _ in throw URLError(.notConnectedToInternet) }),
                baseURL: server.base.appendingPathComponent("drive/v3/"), metadataDirectory: scratch.url)

            return (DriveProvider(accountID: client.accountID, client: down), down.metadataCache.storage)
        }
    }

    @Test @MainActor func oneDriveSharedOwnerSeedsForeignDriveWithoutCrossDriveIdentityLeaks() async throws {
        let server = try FakeGraphServer(), client = try server.client(), provider = OneDriveProvider(client: client)

        let foreign = provider.drive(FakeGraphServer.otherDrive)

        foreign.metadataCache.setRetentionLimits(.init(files: 0, listings: 0, bytes: 0))
        let root = OneDriveLocation(accountID: client.accountID, itemID: "collection:shared").url
        let source = CloudSource(location: root, provider: provider)
        source.retainMetadata(for: [root])
        let rows = try await provider.refresh(root)
        await foreign.metadataCache.settleRetention()
        #expect(foreign.metadataCache.files.isEmpty)
        // Typed collection snapshot reseeds foreign records even when pruning beat the main-thread delivery.
        source.retainMetadata(for: [root])
        await foreign.metadataCache.settleRetention()
        #expect(rows.allSatisfy { provider.metadata($0.url) != nil })
        let unrelated = provider.drive("unrelated-drive")
        #expect(unrelated.metadataCache.file("OTHER!folder") == nil)
        source.retainMetadata(for: [])
        await foreign.metadataCache.settleRetention()
        #expect(foreign.metadataCache.files.isEmpty)
    }

    @Test @MainActor func dropboxOwnersAreScopedToTheirNamespaces() async throws {
        let server = try FakeDropboxServer(), client = try server.client(), provider = DropboxProvider(client: client)

        let root = DropboxLocation(accountID: client.accountID).url
        let otherRoot = DropboxLocation(accountID: client.accountID, namespaceID: "other-namespace").url
        let other = try provider.scoped(otherRoot)

        let source = CloudSource(location: root, provider: provider)
        source.retainMetadata(for: [root, otherRoot])
        let ownRows = try await provider.refresh(root), otherRows = try await provider.refresh(otherRoot)
        client.metadataCache.setRetentionLimits(.init(files: 0, listings: 0, bytes: 0))
        other.metadataCache.setRetentionLimits(.init(files: 0, listings: 0, bytes: 0))
        source.retainMetadata(for: [root, otherRoot])
        await client.metadataCache.settleRetention(); await other.metadataCache.settleRetention()
        #expect(provider.cachedListing(root) == ownRows && provider.cachedListing(otherRoot) == otherRows)
        source.retainMetadata(for: [otherRoot])
        await client.metadataCache.settleRetention(); await other.metadataCache.settleRetention()
        #expect(provider.cachedListing(root) == nil && provider.cachedListing(otherRoot) == otherRows)
        source.retainMetadata(for: [])
        await other.metadataCache.settleRetention()
        #expect(provider.cachedListing(otherRoot) == nil)
        await provider.stopFeeds()
    }
}
