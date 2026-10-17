import AppKit
import PorpoiseCore
import PorpoiseServices
import Testing

@testable import Porpoise

/// Shared cloud UI words and rules come from the service the item is in, never Google Drive's by default.
@MainActor @Suite(.serialized) struct ProviderNeutralUITests {
    private let account = UUID()
    private var dropboxRoot: URL { DropboxLocation(accountID: account).url }
    private var dropboxFolder: URL { DropboxLocation(accountID: account, itemID: "id:folder").url }
    private var dropboxFile: URL { DropboxLocation(accountID: account, itemID: "id:file").url }

    /// The shared accounts with a demo service that knows a Dropbox file's folders, for the length of `body`.
    private func withDemo(_ body: (DemoCloudBackend) throws -> Void) rethrows {
        let previous = CloudAccounts.shared.backend
        let demo = DemoCloudBackend(accounts: [
            CloudAccount(id: "acct", email: "me@example.com", displayName: "Me"),
            CloudAccount(id: account.uuidString.lowercased(), provider: .dropbox, email: "me@example.com", displayName: "Me"),
        ])
        demo.ancestry[dropboxFile] = [dropboxRoot, dropboxFolder]
        CloudAccounts.shared.backend = demo
        defer { CloudAccounts.shared.backend = previous }
        try body(demo)
    }

    // B1
    @Test func editBadgeTipsNameTheService() {
        let tip = CloudBadge.help(.edit(.editing), of: dropboxFile)
        #expect(tip == "Editing · changes save to Dropbox")
        #expect(
            CloudBadge.help(.edit(.conflict), of: URL(string: "gdrive://a/my-drive/x")!) == "Changed in Google Drive meanwhile · review in Activity")
    }

    // B10: the folders above a Dropbox item, in Properties and in the breadcrumb.
    @Test func propertiesAndBreadcrumbShowDropboxParents() {
        withDemo { _ in
            let location = PropertiesWindow.cloudLocation(of: dropboxFile)
            #expect(location.hasPrefix("Dropbox › "))
            #expect(location.components(separatedBy: " › ").count == 3)  // the account, its root, the folder
            let crumbs = BreadcrumbView(frame: .zero)
            crumbs.url = dropboxFile
            #expect(crumbs.cloudCrumbs().map(\.url).suffix(3) == [dropboxRoot, dropboxFolder, dropboxFile])
            #expect(crumbs.cloudCrumbs().first?.title == "Dropbox")
            // Drive's locations still carry theirs.
            let drive = URL(string: "gdrive://acct/my-drive/f1/f2")!
            crumbs.url = drive
            #expect(
                crumbs.cloudCrumbs().map(\.url).suffix(3) == [
                    URL(string: "gdrive://acct/my-drive/")!, URL(string: "gdrive://acct/my-drive/f1/")!, drive,
                ])
            #expect(PropertiesWindow.cloudLocation(of: drive).hasPrefix("Google Drive › "))
        }
    }

    // B11: Drive keeps both; Dropbox refuses an existing name, ignoring case.
    @Test func newFolderNameRulesFollowTheService() {
        let names: Set<String> = ["Reports"]
        let drive = URL(string: "gdrive://acct/my-drive/")!
        #expect(NewItemDialog.cloudNameProblem("Reports", names: names, in: drive)?.isError == false)
        #expect(NewItemDialog.cloudNameProblem("Reports", names: names, in: drive)?.message.contains("Both will be kept") == true)
        #expect(NewItemDialog.cloudNameProblem("reports", names: names, in: dropboxRoot)?.isError == true)
        #expect(NewItemDialog.cloudNameProblem("reports", names: names, in: dropboxRoot)?.message.contains("Both will be kept") == false)
        #expect(NewItemDialog.cloudNameProblem("Other", names: names, in: dropboxRoot) == nil)
    }

    // B12: cloud and server places take drops; locations with no folder of their own don't.
    @Test func cloudAndServerPlacesTakeDrops() {
        withDemo { _ in
            #expect(PlacesPanel.takesDrops(dropboxFolder))
            #expect(PlacesPanel.takesDrops(URL(string: "gdrive://acct/my-drive/")!))
            #expect(PlacesPanel.takesDrops(URL(string: "sftp://me@host/home/me/")!))
            #expect(PlacesPanel.takesDrops(URL(fileURLWithPath: NSHomeDirectory())))
            #expect(!PlacesPanel.takesDrops(URL(string: "recent:/files")!))
            #expect(!PlacesPanel.takesDrops(URL(string: "smb://server/share")!))
            // A place of an account that isn't connected takes nothing, as its folder wouldn't.
            #expect(!PlacesPanel.takesDrops(URL(string: "gdrive://gone/my-drive/")!))
        }
    }

    @Test func sharedWithMeTakesNoDrops() {
        let demo = DemoCloudBackend(accounts: [CloudAccount(id: "acct", email: "me@example.com", displayName: "Me")])
        let previous = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = demo
        defer { CloudAccounts.shared.backend = previous }
        let shared = URL(string: "gdrive://acct/shared-with-me/")!
        demo.permissionsByURL[shared] = CloudPermissions(collection: .sharedWithMe)
        #expect(!PlacesPanel.takesDrops(shared))
    }
}
