import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// DropboxConfigurationTests, LocationKindTests and RemoteFolderTreeTests' provider checks, for OneDrive.
struct OneDriveConfigurationTests {
    @Test func clientIDPrecedenceEmptyValuesAndDescriptorAvailability() throws {
        let scratch = try Scratch()
        func bundle(_ name: String, _ info: [String: Any]) throws -> Bundle {
            let directory = scratch.url.appendingPathComponent(name + ".bundle")
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: directory.appendingPathComponent("Contents/Info.plist"))
            return try #require(Bundle(url: directory))
        }
        let bundled = try bundle("Configured", ["CFBundleIdentifier": "test.onedrive.configuration", "OneDriveClientID": " bundled-id "])
        let empty = try bundle("Empty", ["CFBundleIdentifier": "test.onedrive.empty"])
        #expect(!OneDriveConfiguration.selected(defaults: MemoryDefaults(), environment: [:], bundle: empty).isConfigured)
        let defaults = MemoryDefaults()
        func selected(_ environment: [String: String] = [:]) -> OneDriveConfiguration {
            .selected(defaults: defaults, environment: environment, bundle: bundled, testing: true)
        }
        #expect(selected().clientID == "bundled-id")
        defaults.set(" settings-id ", forKey: "oneDriveClientID")
        #expect(selected().clientID == "settings-id")
        #expect(selected(["PORPOISE_ONEDRIVE_CLIENT_ID": " env-id "]).clientID == "env-id")
        #expect(selected(["PORPOISE_ONEDRIVE_CLIENT_ID": " \n "]).clientID == "settings-id")
        defaults.set(" \n ", forKey: "oneDriveClientID")
        #expect(selected(["PORPOISE_ONEDRIVE_CLIENT_ID": ""]).clientID == "bundled-id")
        for id in ["", " \n ", "configured-id"] {
            let descriptor = try #require(
                CloudProviderDescriptor.catalog(dropbox: .init(appKey: ""), oneDrive: .init(clientID: id)).first { $0.provider == .oneDrive })
            #expect(descriptor.available == (id == "configured-id"))
        }
        let remote = OneDriveLocation(accountID: UUID()).url
        #expect(PlacesModel.isCloud(remote) && CloudProviderDescriptor.descriptor(for: remote)?.provider == .oneDrive)
        // Production endpoints are Microsoft's, over HTTPS; only Graph's own host gets a bearer.
        let production = OneDriveConfiguration(clientID: "id")
        #expect([production.authorizationURL, production.tokenURL, production.graphURL].allSatisfy { $0.scheme == "https" })
        #expect(production.isGraph(URL(string: "https://graph.microsoft.com/v1.0/me/drive/root/delta?token=x")!))
        for other in [
            "https://graph.microsoft.com.example.com/v1.0", "http://graph.microsoft.com/v1.0", "https://u:p@graph.microsoft.com/",
            "https://my.sharepoint.com/download",
        ] {
            #expect(!production.isGraph(URL(string: other)!), "\(other)")
        }
    }

    @Test(.isolatedSettings) func changingTheSettingUpdatesAvailabilityWithoutRestart() {
        let external = OneDriveConfiguration.selected(defaults: MemoryDefaults()).isConfigured
        if !external {
            #expect(!CloudProvider.oneDrive.isAvailable)
            let accounts = CloudAccounts(); let backend = DemoCloudBackend(); accounts.backend = backend
            var refused = false
            _ = accounts.connect(.oneDrive, openBrowser: { _ in Issue.record("Unexpected browser") }) { if case .failure = $0 { refused = true } }
            #expect(refused && !backend.isSigningIn)
        }
        Settings.store.set("fixture-settings-id", forKey: "oneDriveClientID")
        #expect(CloudProvider.oneDrive.isAvailable)
        Settings.store.removeObject(forKey: "oneDriveClientID")
        #expect(CloudProvider.oneDrive.isAvailable == external)
    }

    @Test func cloudNamesUseProviderMetadataAndServiceFallbacks() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        let provider = OneDriveProvider(client: client)
        let root = OneDriveLocation(accountID: client.accountID).url
        RemoteFS.registerCloud(provider, for: root)
        defer { RemoteFS.registerCloud(nil, for: root) }
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        #expect(LocationNaming.name(for: file.url) == "hello.txt")
        #expect(LocationNaming.connectionTitle(for: file.url) == "hello.txt")
        #expect(LocationNaming.context(for: file.url) == "OneDrive")
        #expect(LocationNaming.name(for: root) == "My files")
        let unknown = OneDriveLocation(accountID: client.accountID, itemID: "FIXTURE!opaque-not-cached", driveID: FakeGraphServer.drive).url
        #expect(LocationNaming.name(for: unknown) == "OneDrive")
        #expect(RemoteFS.displayName(for: file.url) == LocationNaming.name(for: file.url))
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func lazyTreeAndDriveIdentity() async throws {
        let server = try FakeGraphServer(); let client = try server.client()
        let provider = OneDriveProvider(client: client)
        let root = OneDriveLocation(accountID: client.accountID).url
        let home = OneDriveLocation(accountID: client.accountID, driveID: FakeGraphServer.drive).url
        RemoteFS.registerCloud(provider, for: root)
        defer { RemoteFS.registerCloud(nil, for: root) }
        #expect(provider.sameItem(root, home))
        #expect(!provider.sameItem(root, OneDriveLocation(accountID: client.accountID, driveID: FakeGraphServer.otherDrive).url))
        let tree = RemoteFolderTree(url: root)
        #expect(tree.root.children == nil && tree.root.isExpandable)
        #expect(try await server.requests().isEmpty)
        tree.root.expand()
        await expectEventually { !tree.root.isLoading && tree.root.children != nil }
        let folder = try #require(tree.root.children?.first { $0.name == "Folder" })
        #expect(OneDriveLocation(url: folder.url)?.driveID == FakeGraphServer.drive)
        // The root's real ID names the root too.
        #expect(provider.sameItem(root, OneDriveLocation(accountID: client.accountID, itemID: "ROOT!101", driveID: FakeGraphServer.drive).url))
        #expect(!provider.sameItem(root, folder.url))
    }

    // The file manager's synchronous provider calls (download, upload, rename, move, copy, delete), off the pool.
    @Test func providerOperationsRoundTripFilesAndFolders() async throws {
        let server = try FakeGraphServer(); let client = try server.client(), scratch = try Scratch()
        let provider = OneDriveProvider(client: client)
        let root = OneDriveLocation(accountID: client.accountID).url
        RemoteFS.registerCloud(provider, for: root)
        defer { RemoteFS.registerCloud(nil, for: root) }
        let listing = try await offThePool { try provider.list(root) }
        let folder = try #require(listing.first { $0.name == "Folder" }), hello = try #require(listing.first { $0.name == "hello.txt" })
        #expect(provider.displayName(for: root) == "My files" && provider.rootTitle(folder.url) == "Folder")
        #expect(try await offThePool { try provider.transferItem(hello.url) }.name == "hello.txt")
        let out = try scratch.folder("out")
        let file = try await offThePool { try provider.download(hello.url, into: out) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "Hello from the OneDrive fixture.")
        let tree = try await offThePool { try provider.download(folder.url, into: out) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.path) == ["nested.txt"])
        let upload = try scratch.folder("Upload"); _ = try scratch.file("Upload/inner.txt", "inner");
        let single = try scratch.file("single.txt", "one")
        try await offThePool {
            try provider.upload(upload, into: root); try provider.upload(single, into: folder.url)
        }
        let after = try await offThePool { try provider.list(root) }
        let uploaded = try #require(after.first { $0.name == "Upload" })
        #expect(try await offThePool { try provider.list(uploaded.url) }.map(\.name) == ["inner.txt"])
        #expect(try await offThePool { try provider.list(folder.url) }.contains { $0.name == "single.txt" })
        try await offThePool { try provider.rename(hello.url, to: "renamed.txt") }
        #expect(provider.metadata(hello.url)?.name == "renamed.txt")
        try await offThePool {
            try provider.copy([hello.url], into: uploaded.url); try provider.move([hello.url], into: folder.url)
        }
        #expect(provider.metadata(hello.url)?.parentID == folder.url.lastPathComponent.removingPercentEncoding)
        #expect(try await offThePool { try provider.list(uploaded.url) }.contains { $0.name == "renamed.txt" })
        let other = try #require(after.first { $0.name == "other.txt" })
        try await offThePool { try provider.delete([other.url]) }
        await #expect(throws: OneDriveError.notFound) { try await client.metadata("FIXTURE!other") }
        #expect(throws: OneDriveError.invalidLocation) { try provider.makeFolder(root) }
        #expect(throws: OneDriveError.invalidLocation) { try provider.location(DropboxLocation(accountID: client.accountID).url) }
        let shared = OneDriveLocation(accountID: client.accountID, itemID: "collection:shared", driveID: FakeGraphServer.drive).url
        #expect(throws: OneDriveError.invalidLocation) { try provider.folderID(shared) }
        #expect(provider.displayName(for: shared) == "Shared with me")
        await provider.prefetch([uploaded.url]); #expect(provider.cachedListing(uploaded.url) != nil)
        let image = try await provider.preview(hello.url, thumbnail: true)
        #expect(try Data(contentsOf: image) == Data("fixture-thumbnail".utf8))
        provider.setActive(true); try await provider.checkForChanges(); await provider.stopFeeds()
    }
}
