import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.isolatedSettings) struct FilePathNotificationTests {
    @MainActor @Test func cloudLookupPreservesProviderItemIdentityWithoutCollapsingNamespaces() {
        let account = UUID(), otherAccount = UUID()
        let drive = DriveProvider(accountID: account, client: nil)
        RemoteFS.registerDrive(drive, accountID: account)
        defer { RemoteFS.unregisterDrive(accountID: account) }
        let root = DriveLocation(accountID: account).url
        let scoped = DriveLocation(accountID: account, collection: .folder("opaque", driveID: "shared")).url
        let plain = DriveLocation(accountID: account, collection: .folder("opaque", driveID: nil)).url
        let model = DirectoryModel(location: root)
        model.searchResults = [FileItem(url: scoped, name: "folder", isDirectory: true)]
        #expect(model.index(of: plain) == 0)
        #expect(model.index(of: DriveLocation(accountID: otherAccount, collection: .folder("opaque", driveID: nil)).url) == nil)
        let one = DropboxLocation(accountID: account, itemID: "id:file", namespaceID: "one").url
        let two = DropboxLocation(accountID: account, itemID: "id:file", namespaceID: "two").url
        let dropbox = DirectoryModel(location: DropboxLocation(accountID: account, namespaceID: "one").url)
        dropbox.searchResults = [FileItem(url: one, name: "file", isDirectory: false)]
        #expect(dropbox.index(of: two) == nil)
    }

    @Test func changesUseTheSameParentIdentityBeforeAndAfterDeletion() throws {
        let s = try Scratch(), file = try s.file("real/file", "x"), alias = s.path("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: s.path("real"))
        let parent = FilePath.canonical(s.path("real").path)
        let paths = Locked<Set<String>>([])
        let observer = NotificationCenter.default.addObserver(forName: FileOperationsController.foldersChanged, object: nil, queue: nil) { note in
            guard let changed = note.userInfo?["paths"] as? Set<String>, changed.contains(parent) else { return }
            paths.change { $0 = changed }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        FileOperationsController.notifyChanged([alias.appendingPathComponent("file")])
        let before = paths.value
        try FileManager.default.removeItem(at: file)
        FileOperationsController.notifyChanged([alias.appendingPathComponent("file")])
        #expect(paths.value == before)
        #expect(before.contains(parent))
    }
}
