import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Shared cloud UI asks the service, not Google Drive's rules: names, ancestry, duplicate names and share links.
@Suite(.serialized, .isolatedSettings) struct ProviderNeutralCloudTests {
    @MainActor private final class Fixture {
        let server: FakeDropboxServer
        let suite = "porpoise-neutral-" + UUID().uuidString
        let store: DropboxAccountStore
        let backend: DropboxCloudBackend
        let accounts = CloudAccounts()
        init() throws {
            Settings.store.set("fixture-app", forKey: "dropboxAppKey")
            server = try FakeDropboxServer()
            store = DropboxAccountStore(
                defaults: UserDefaults(suiteName: suite)!, credentials: MemoryCredentials(), configuration: server.config,
                directory: server.directory)
            backend = DropboxCloudBackend(store: store)
            accounts.backend = CompositeCloudBackend([.dropbox: backend])
        }
        func connect() async throws -> CloudAccount {
            try await withCheckedThrowingContinuation { continuation in
                _ = accounts.connect(
                    .dropbox, openBrowser: { url in Task { _ = try? await URLSession.shared.data(from: url) } },
                    done: { continuation.resume(with: $0.mapError { $0 as Error }) })
            }
        }
        func resolve(_ text: String) async -> CloudLinkResult {
            await withCheckedContinuation { continuation in accounts.resolveLink(text) { continuation.resume(returning: $0) } }
        }
        func cleanup() {
            backend.setActive(false)
            for account in store.accounts { RemoteFS.registerCloud(nil, for: DropboxLocation(accountID: account.id).url) }
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    // B1: a Dropbox file being edited says Dropbox, also before its account is known.
    @Test func editNotesNameTheService() {
        let accounts = CloudAccounts()
        let dropbox = DropboxLocation(accountID: UUID(), itemID: "id:x").url
        #expect(accounts.providerTitle(for: dropbox) == "Dropbox")
        #expect(CloudEditMark.editing.note(accounts.providerTitle(for: dropbox)) == "Editing · changes save to Dropbox")
        #expect(accounts.providerTitle(for: URL(string: "gdrive://a/my-drive/f")!) == "Google Drive")
        #expect(accounts.providerTitle(for: URL(string: "https://example.com/x")!) == "the cloud")
    }

    // B11: only Drive keeps two items of the same name.
    @Test func duplicateNamesAreTheServicesRule() {
        #expect(CloudProvider.googleDrive.descriptor.allowsDuplicateNames)
        #expect(!CloudProvider.dropbox.descriptor.allowsDuplicateNames)
        #expect(CloudProvider.googleDrive.descriptor.hasWebDocuments && !CloudProvider.dropbox.descriptor.hasWebDocuments)
    }

    // B14: Dropbox share links are links, and go to the Dropbox backend.
    @Test func shareLinksAreRecognizedPerService() {
        #expect(CloudAccounts.looksLikeLink("https://www.dropbox.com/scl/fo/abc/xyz?rlkey=1"))
        #expect(CloudAccounts.looksLikeLink(" https://dropbox.com/s/abc/file.txt "))
        #expect(CloudAccounts.looksLikeLink("https://drive.google.com/drive/folders/x"))
        #expect(!CloudAccounts.looksLikeLink("http://www.dropbox.com/s/abc"))
        #expect(!CloudAccounts.looksLikeLink("https://example.com/s/abc"))
        #expect(CloudProviderDescriptor.linkProvider("https://www.dropbox.com/s/a")?.provider == .dropbox)
        #expect(CloudProviderDescriptor.linkProvider("https://docs.google.com/document/d/x")?.provider == .googleDrive)
    }

    @Test @MainActor func dropboxLinksOpenWithTheAccountThatSeesThem() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        let folderLink = "https://www.dropbox.com/scl/fo/folder/key?rlkey=1"
        let fileLink = "https://www.dropbox.com/scl/fi/hello/hello.txt?rlkey=2"
        let foreign = "https://www.dropbox.com/scl/fi/foreign/x.txt?rlkey=3"
        try await fixture.server.configure(["links": [folderLink: "id:folder", fileLink: "id:hello"], "foreignLinks": [foreign]])
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let uuid = try #require(DropboxLocation(url: root)?.accountID)
        guard case .folder(let folder) = await fixture.resolve(folderLink) else { Issue.record("not a folder"); return }
        #expect(DropboxLocation(url: folder)?.itemID == "id:folder" && DropboxLocation(url: folder)?.accountID == uuid)
        #expect(RemoteFS.displayName(for: folder) == "Folder")
        #expect(fixture.accounts.info(for: folder)?.name == "Folder")  // read once, so the folder shows its name
        guard case .file(let file) = await fixture.resolve(fileLink) else { Issue.record("not a file"); return }
        #expect(DropboxLocation(url: file)?.itemID == "id:hello")
        #expect(await fixture.resolve(foreign) == .noAccess)
        #expect(await fixture.resolve("https://www.dropbox.com/scl/fi/gone/x?rlkey=4") == .noAccess)
        #expect(await fixture.resolve("https://drive.google.com/drive/folders/x") == .notALink)
    }

    // B10: Dropbox locations name only the item; its folders come from the service.
    @Test @MainActor func dropboxAncestryComesFromItsPaths() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let home = try #require(DropboxLocation(url: root)); let uuid = home.accountID, ns = home.namespaceID
        let provider = try #require(RemoteFS.provider(for: root) as? DropboxProvider)
        try await fixture.server.configure([
            "files": [["id": "id:deep", "path": "/Folder/Inner", "folder": true], ["id": "id:leaf", "path": "/Folder/Inner/leaf.txt", "text": "x"]]
        ])
        let top = try await provider.refresh(root) { _, _ in }
        let folder = try #require(top.first { $0.name == "Folder" }).url
        _ = try await provider.refresh(folder) { _, _ in }
        let inner = DropboxLocation(accountID: uuid, itemID: "id:deep", namespaceID: ns).url
        _ = try await provider.refresh(inner) { _, _ in }
        let leaf = DropboxLocation(accountID: uuid, itemID: "id:leaf", namespaceID: ns).url
        let homeRoot = root
        #expect(fixture.accounts.ancestors(of: leaf) == [homeRoot, folder, inner])
        #expect(fixture.accounts.ancestors(of: leaf).map { RemoteFS.displayName(for: $0) } == ["Files", "Folder", "Inner"])
        #expect(fixture.accounts.ancestors(of: folder) == [homeRoot])
        #expect(fixture.accounts.ancestors(of: root).isEmpty)
        let entry = CloudEditEntry(
            id: UUID(), account: uuid, fileID: "id:leaf", name: "leaf.txt", localURL: URL(fileURLWithPath: "/tmp/leaf.txt"), mark: .editing,
            location: leaf, provider: .dropbox)
        let previous = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = fixture.accounts.backend
        defer { CloudAccounts.shared.backend = previous }
        #expect(entry.folder == inner)  // Show in Folder opens the file's folder, not the account
    }

    @Test @MainActor func dropboxAncestorsNotReadYetAreFetched() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let home = try #require(DropboxLocation(url: root)); let uuid = home.accountID, ns = home.namespaceID
        let provider = try #require(RemoteFS.provider(for: root) as? DropboxProvider)
        // Only the item itself is known (opened from a link): its folder is read in the background.
        fixture.backend.setActive(false)
        let client = try provider.scoped(root)
        await client.changes.stop()
        client.metadataCache.clear()
        _ = try await client.metadata("id:nested")
        let nested = DropboxLocation(accountID: uuid, itemID: "id:nested", namespaceID: ns).url
        #expect(fixture.accounts.ancestors(of: nested) == [root])
        let deadline = Date().addingTimeInterval(10)
        while fixture.accounts.ancestors(of: nested).count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(fixture.accounts.ancestors(of: nested) == [root, DropboxLocation(accountID: uuid, itemID: "id:folder", namespaceID: ns).url])
    }

    @Test @MainActor func aDropboxItemNotReadYetIsReadThenItsFolders() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try await fixture.connect()
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        let home = try #require(DropboxLocation(url: root)); let uuid = home.accountID, ns = home.namespaceID
        let provider = try #require(RemoteFS.provider(for: root) as? DropboxProvider)
        fixture.backend.setActive(false)
        let client = try provider.scoped(root)
        await client.changes.stop()
        client.metadataCache.clear()
        // Nothing is known about the item (a raw location): it is read, then its folder; each step tells the views.
        let nested = DropboxLocation(accountID: uuid, itemID: "id:nested", namespaceID: ns).url
        var notices = 0
        let token = NotificationCenter.default.addObserver(forName: CloudAccounts.remoteChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { notices += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(fixture.accounts.ancestors(of: nested) == [root])
        let folder = DropboxLocation(accountID: uuid, itemID: "id:folder", namespaceID: ns).url
        let deadline = Date().addingTimeInterval(10)
        // The folder is in the cache a moment before the views are told.
        while fixture.accounts.ancestors(of: nested) != [root, folder] || notices < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fixture.accounts.ancestors(of: nested) == [root, folder])
        #expect(notices >= 2)
    }

    // Drive (and the demo service): the ancestry is in the location.
    @Test func pathLocationsCarryTheirAncestry() {
        let demo = DemoCloudBackend()
        #expect(
            demo.ancestors(of: URL(string: "gdrive://a/my-drive/f1/f2?resourcekey=k")!)
                == [URL(string: "gdrive://a/my-drive/")!, URL(string: "gdrive://a/my-drive/f1/")!])
        #expect(demo.ancestors(of: URL(string: "gdrive://a/folder/f1")!).isEmpty)
        #expect(demo.ancestors(of: URL(string: "gdrive://a/my-drive/")!).isEmpty)
        let u = URL(string: "dropbox://x/id:1")!
        demo.ancestry[u] = [URL(string: "dropbox://x/")!]
        #expect(demo.ancestors(of: u) == [URL(string: "dropbox://x/")!])
    }
}
