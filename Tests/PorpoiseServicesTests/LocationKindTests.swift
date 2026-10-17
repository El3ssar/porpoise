import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

@Suite(.isolatedSettings) @MainActor struct LocationKindTests {
    @Test func classifiesLocationsWithoutConfusingProvidersWithVirtualLists() {
        let cases: [(String, LocationKind)] = [
            ("file:///tmp/folder/", .local), ("gdrive://account/my-drive/", .cloud(.googleDrive)),
            ("dropbox://account/id%3Aitem", .cloud(.dropbox)),
            ("sftp://me@fixture.invalid/folder/", .remote), ("ssh://fixture.invalid/", .remote),
            ("fish://fixture.invalid/", .remote), ("scp://fixture.invalid/", .remote),
            ("ftp://fixture.invalid/", .remote), ("ftps://fixture.invalid/", .remote),
            ("adb://fixture-device/sdcard/", .device), ("smb://fixture.invalid/share/", .networkShare),
            ("afp://fixture.invalid/share/", .networkShare), ("nfs://fixture.invalid/share/", .networkShare),
            ("webdavs://fixture.invalid/share/", .networkShare), ("network:/", .network),
            ("recent:/files", .recentFiles), ("recent:/locations", .recentLocations),
            ("tags:/Red", .tag), ("smart:/tmp/Work.savedSearch", .smartFolder),
            ("https://example.invalid/", .unsupported), ("mtp://fixture-device/", .unsupported),
        ]
        for (string, expected) in cases {
            let url = URL(string: string)!
            let kind = LocationKind.of(url)
            #expect(kind == expected)
            #expect(kind.isVirtual == [.network, .recentFiles, .recentLocations, .tag, .smartFolder].contains(expected))
            #expect(kind.isResultList == (kind.isVirtual && expected != .network))
            #expect(kind.isSupported == (expected != .unsupported))
            #expect(kind.persistsViewStyle == kind.isSupported)
            #expect(kind.acceptsDrops == kind.hasHierarchy)
            #expect(RemoteFS.isRemote(url) == kind.isRemote)
            #expect(PlacesModel.isCloud(url) == kind.isCloud)
            #expect(!kind.icon.isEmpty)
            #expect(DirectoryModel(location: url).kind == expected)
        }
        #expect(LocationKind.of(TrashInfo.folder) == .trash)
        #expect(LocationKind.of(TrashInfo.folder).isLocal)
        #expect(LocationKind.of(TrashInfo.folder).title == "Trash")
        #expect(LocationKind.of(URL(string: "SFTP://fixture.invalid/folder/")!) == .remote)
    }

    @Test func navigationCapabilitiesKeepRootsAndVirtualListsDistinct() {
        for string in ["file:///", "sftp://fixture.invalid/", "adb://fixture-device/"] {
            let url = URL(string: string)!
            #expect(!LocationKind.of(url).canGoUp(from: url))
        }
        for string in ["file:///tmp/folder/", "sftp://fixture.invalid/folder/", "gdrive://account/my-drive/", "dropbox://account/id%3Afolder"] {
            let url = URL(string: string)!
            #expect(LocationKind.of(url).canGoUp(from: url))
        }
        for string in ["network:/", "recent:/files", "tags:/Red", "smart:/tmp/Work.savedSearch", "smb://fixture.invalid/share/"] {
            let url = URL(string: string)!
            #expect(!LocationKind.of(url).canGoUp(from: url) && !LocationKind.of(url).acceptsDrops)
        }
    }

    @Test func namesAndClipboardAddressesAreSharedAndNeverExposePasswords() {
        let local = URL(fileURLWithPath: "/tmp/Some Folder")
        let remote = URL(string: "sftp://alice:fixture-secret@fixture.invalid/folder/")!
        let recent = PlacesModel.recentFilesURL
        #expect(LocationNaming.name(for: local) == "Some Folder")
        #expect(LocationNaming.name(for: URL(fileURLWithPath: "/")) == "/")
        #expect(LocationNaming.name(for: recent) == "Recent Files")
        #expect(LocationNaming.name(for: URL(string: "recent:/locations")!) == "Recent Locations")
        #expect(LocationNaming.name(for: URL(string: "network:/")!) == "Network")
        #expect(LocationNaming.name(for: URL(string: "smart:/tmp/Work.savedSearch")!) == "Work")
        #expect(LocationNaming.name(for: URL(string: "tags:/Red")!) == "Red")
        #expect(LocationNaming.name(for: URL(string: "sftp://alice@fixture.invalid/")!) == "alice@fixture.invalid")
        #expect(LocationNaming.name(for: remote) == "folder")
        #expect(LocationNaming.name(for: URL(string: "sftp://fixture.invalid/~/")!) == "Home")
        #expect(LocationNaming.name(for: URL(string: "smb://fixture.invalid/")!) == "fixture.invalid")
        #expect(LocationNaming.connectionTitle(for: remote) == "fixture.invalid")
        #expect(local.folderName == LocationNaming.name(for: local))
        #expect(LocationNaming.icon(for: local) == IconTheme.folderIconName(local))
        #expect(LocationNaming.icon(for: URL(string: "adb://fixture-device/")!) == "smartphone")
        #expect(LocationNaming.context(for: local) == "/tmp")
        #expect(LocationNaming.context(for: remote) == "sftp · fixture.invalid")
        #expect(
            LocationNaming.clipboardText(for: [local, remote, recent]) == "/tmp/Some Folder\nsftp://alice@fixture.invalid/folder/\nrecent:/files")
        #expect(LocationNaming.clipboardText(for: []).isEmpty)
    }

    @Test func cloudNamesUseProviderMetadataAndServiceFallbacks() async throws {
        let server = try FakeDropboxServer(); let client = try server.client()
        let provider = DropboxProvider(client: client)
        let root = DropboxLocation(accountID: client.accountID).url
        RemoteFS.registerCloud(provider, for: root)
        defer { RemoteFS.registerCloud(nil, for: root) }
        let file = try #require(try await provider.refresh(root).first { $0.name == "hello.txt" })
        #expect(LocationNaming.name(for: file.url) == "hello.txt")
        #expect(LocationNaming.connectionTitle(for: file.url) == "hello.txt")
        #expect(LocationNaming.context(for: file.url) == "Dropbox")
        #expect(LocationNaming.name(for: root) == "Files")
        let unknown = DropboxLocation(accountID: client.accountID, itemID: "id:opaque-not-cached").url
        #expect(LocationNaming.name(for: unknown) == "Dropbox")
        #expect(RemoteFS.displayName(for: file.url) == LocationNaming.name(for: file.url))
        let places = PlacesModel(storeURL: server.directory.appendingPathComponent("test-places.json"))
        places.add(file.url)
        #expect(places.userEntries.first { $0.url == file.url }?.title == "hello.txt")
    }
    @Test func driveNamesUseTheSameCachedMetadataPath() async throws {
        let server = try FakeDriveServer(); let (client, _, _) = try server.client()
        let provider = DriveProvider(accountID: client.accountID, client: client)
        RemoteFS.registerDrive(provider, accountID: client.accountID)
        defer { RemoteFS.unregisterDrive(accountID: client.accountID) }
        let root = DriveLocation(accountID: client.accountID).url
        let file = try #require(try await provider.refresh(root).first { $0.name == "report.txt" })
        #expect(LocationNaming.name(for: file.url) == "report.txt")
        #expect(LocationNaming.name(for: root) == "My Drive")
        #expect(LocationNaming.context(for: file.url) == "Google Drive")
        let unknown = DriveLocation(accountID: client.accountID, collection: .folder("uncached-opaque-id")).url
        #expect(LocationNaming.name(for: unknown) == "Google Drive")
        #expect(LocationNaming.context(for: URL(string: "recent:/files")!) == "recent:/files")
        #expect(LocationKind.trash.icon == "user-trash")
    }

}
