import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The shared cloud UI's questions (names, ancestry, duplicate names, share links) answered by OneDrive, as
/// ProviderNeutralCloudTests has Dropbox and Drive answer them.
@Suite(.serialized, .isolatedSettings) struct ProviderNeutralOneDriveTests {
    typealias Fixture = OneDriveParityTests.Fixture
    @MainActor func connect(_ fixture: Fixture) async throws -> (CloudAccount, URL, OneDriveProvider) {
        let account = try await fixture.connect().get()
        let root = try #require(fixture.accounts.url(account.id, root: .myDrive))
        return (account, root, try #require(RemoteFS.provider(for: root) as? OneDriveProvider))
    }
    @MainActor func resolve(_ fixture: Fixture, _ text: String) async throws -> CloudLinkResult {
        try await awaitCallback { continuation in fixture.accounts.resolveLink(text) { continuation.resume(returning: $0) } }
    }

    @Test func editNotesDuplicateNamesAndLinksAreOneDrives() {
        let accounts = CloudAccounts()
        let url = OneDriveLocation(accountID: UUID(), itemID: "ID!1", driveID: "d").url
        #expect(accounts.providerTitle(for: url) == "OneDrive")
        #expect(CloudEditMark.editing.note(accounts.providerTitle(for: url)) == "Editing · changes save to OneDrive")
        #expect(!CloudProvider.oneDrive.descriptor.allowsDuplicateNames && !CloudProvider.oneDrive.descriptor.hasWebDocuments)
        #expect(CloudAccounts.looksLikeLink("https://1drv.ms/f/s!AbCdEf"))
        #expect(CloudAccounts.looksLikeLink(" https://onedrive.live.com/redir?resid=ABC!1 "))
        #expect(!CloudAccounts.looksLikeLink("http://1drv.ms/f/s!AbCdEf"))
        #expect(CloudProviderDescriptor.linkProvider("https://1drv.ms/u/s!x")?.provider == .oneDrive)
        #expect(CloudProviderDescriptor.descriptor(for: url)?.provider == .oneDrive)
        #expect(CloudProvider.oneDrive.descriptor.configuration?.key == "oneDriveClientID")
    }

    @Test @MainActor func linksOpenWithTheAccountThatSeesThem() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try await connect(fixture)
        let folderLink = "https://1drv.ms/f/s!folder-link", fileLink = "https://1drv.ms/t/s!file-link", foreign = "https://1drv.ms/t/s!foreign"
        try await fixture.server.configure(["links": [folderLink: "FIXTURE!folder", fileLink: "OTHER!shared.txt"], "foreignLinks": [foreign]])
        guard case .folder(let folder) = try await resolve(fixture, folderLink) else { Issue.record("not a folder"); return }
        #expect(OneDriveLocation(url: folder)?.itemID == "FIXTURE!folder" && OneDriveLocation(url: folder)?.driveID == FakeGraphServer.drive)
        #expect(RemoteFS.displayName(for: folder) == "Folder")
        #expect(fixture.accounts.info(for: folder)?.name == "Folder")
        // A link to someone else's file opens in their drive.
        guard case .file(let file) = try await resolve(fixture, fileLink) else { Issue.record("not a file"); return }
        #expect(OneDriveLocation(url: file)?.driveID == FakeGraphServer.otherDrive && fixture.accounts.info(for: file)?.name == "shared.txt")
        #expect(try await resolve(fixture, foreign) == .noAccess)
        #expect(try await resolve(fixture, "https://1drv.ms/t/s!gone") == .noAccess)
        #expect(try await resolve(fixture, "https://www.dropbox.com/s/abc") == .notALink)
        let shares = try await fixture.server.requests().filter { ($0["route"] as? String)?.hasPrefix("/v1.0/shares/u!") == true }
        #expect(shares.count == 4)
    }

    // OneDrive locations name only the item: its folders come from the parent IDs the service gives.
    @Test @MainActor func ancestryComesFromParentIDs() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (account, root, provider) = try await connect(fixture)
        let uuid = try #require(OneDriveLocation(url: root)?.accountID), drive = FakeGraphServer.drive
        try await fixture.server.configure([
            "files": [
                ["id": "FIXTURE!inner", "name": "Inner", "folder": true, "parent": "FIXTURE!folder"],
                ["id": "FIXTURE!leaf", "name": "leaf.txt", "parent": "FIXTURE!inner", "text": "x"],
            ]
        ])
        let top = try await provider.refresh(root) { _, _ in }
        let folder = try #require(top.first { $0.name == "Folder" }).url
        _ = try await provider.refresh(folder) { _, _ in }
        let inner = OneDriveLocation(accountID: uuid, itemID: "FIXTURE!inner", driveID: drive).url
        _ = try await provider.refresh(inner) { _, _ in }
        let leaf = OneDriveLocation(accountID: uuid, itemID: "FIXTURE!leaf", driveID: drive).url
        #expect(fixture.accounts.ancestors(of: leaf) == [root, folder, inner])
        #expect(fixture.accounts.ancestors(of: leaf).map { RemoteFS.displayName(for: $0) } == ["My files", "Folder", "Inner"])
        #expect(fixture.accounts.ancestors(of: folder) == [root])
        #expect(fixture.accounts.ancestors(of: root).isEmpty)
        let entry = CloudEditEntry(
            id: UUID(), account: uuid, fileID: "FIXTURE!leaf", name: "leaf.txt", localURL: URL(fileURLWithPath: "/tmp/leaf.txt"), mark: .editing,
            location: leaf, provider: .oneDrive)
        let previous = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = fixture.accounts.backend
        defer { CloudAccounts.shared.backend = previous }
        #expect(entry.folder == inner)  // Show in Folder opens the file's folder, not the account
        #expect(fixture.accounts.accounts.first?.id == account.id)
    }

    @Test @MainActor func anItemNotReadYetIsReadThenItsFolders() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (_, root, provider) = try await connect(fixture)
        let uuid = try #require(OneDriveLocation(url: root)?.accountID)
        fixture.backend.setActive(false)
        let client = try provider.scoped(root)
        await client.changes.stop()
        client.metadataCache.clear()
        let nested = OneDriveLocation(accountID: uuid, itemID: "FIXTURE!nested", driveID: FakeGraphServer.drive).url
        var notices = 0
        let token = NotificationCenter.default.addObserver(forName: CloudAccounts.remoteChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { notices += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(fixture.accounts.ancestors(of: nested) == [root])
        let folder = OneDriveLocation(accountID: uuid, itemID: "FIXTURE!folder", driveID: FakeGraphServer.drive).url
        await expectEventually { fixture.accounts.ancestors(of: nested) == [root, folder] && notices >= 2 }
        #expect(fixture.accounts.ancestors(of: nested) == [root, folder])
        #expect(notices >= 2)
    }

    // What others shared lists under Shared with me and opens in its owner's drive, read with this account's sign-in.
    @Test @MainActor func sharedItemsOpenInTheirOwnersDrive() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (account, _, provider) = try await connect(fixture)
        let shared = try #require(fixture.accounts.url(account.id, root: .sharedWithMe))
        #expect(RemoteFS.displayName(for: shared) == "Shared with me")
        #expect(fixture.accounts.permissions(for: shared)?.collection == .sharedWithMe)
        let items = try await provider.refresh(shared) { _, _ in }
        let folder = try #require(items.first { $0.name == "Shared Folder" })
        #expect(folder.isDirectory && OneDriveLocation(url: folder.url)?.driveID == FakeGraphServer.otherDrive)
        #expect(RemoteFS.displayName(for: folder.url) == "Shared Folder")
        let inside = try await provider.refresh(folder.url) { _, _ in }
        #expect(inside.map(\.name) == ["inside.txt"])
        let file = try #require(inside.first)
        let local = try await provider.preview(file.url)
        #expect(try String(contentsOf: local, encoding: .utf8) == "Inside a shared folder.")
        #expect(try provider.scoped(file.url) !== provider.client)
        #expect(fixture.backend.content(for: file.url)?.accountID.hasSuffix(FakeGraphServer.otherDrive) == true)
    }

    // Search finds what's in a folder (or everywhere), page by page.
    @Test @MainActor func searchPagesWithinAFolderOrEverywhere() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (_, root, provider) = try await connect(fixture)
        _ = try await provider.refresh(root) { _, _ in }
        func search(_ folder: URL, everywhere: Bool, token: String? = nil) async throws -> CloudSearchPage {
            try await awaitCallback { continuation in
                _ = fixture.backend.search("txt", in: folder, everywhere: everywhere, contents: false, pageToken: token) {
                    continuation.resume(with: $0)
                }
            }
        }
        let first = try await search(root, everywhere: true)
        let second = try await search(root, everywhere: true, token: first.nextPageToken)
        #expect(Set((first.items + second.items).map(\.name)) == ["hello.txt", "other.txt", "nested.txt"] && second.nextPageToken == nil)
        let here = try await search(root, everywhere: false)
        #expect(here.items.allSatisfy { $0.name != "nested.txt" })
    }
}
