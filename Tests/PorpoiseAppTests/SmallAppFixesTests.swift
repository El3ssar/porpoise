import AppKit
import PorpoiseCore
import PorpoiseServices
import Testing

@testable import Porpoise

/// Context menus, the icon cache and the capacity bar do what fits the location.
@MainActor @Suite(.serialized) struct SmallAppFixesTests {
    // B8: "Open Path" only where items are listed away from their folder.
    @Test func openPathOnlyWhereItemsAreListedElsewhere() {
        #expect(LocationKind.of(URL(string: "recent:/files")!).isResultList)
        #expect(LocationKind.of(URL(string: "tags:/Red")!).isResultList)
        #expect(LocationKind.of(URL(string: "smart:/Big.savedSearch")!).isResultList)
        for folder in ["gdrive://acct/my-drive/f1", "dropbox://acct/id:x", "sftp://me@host/home/me/", "file:///Users", "network:/"] {
            #expect(!LocationKind.of(URL(string: folder)!).isResultList, "\(folder)")
        }
    }

    // B18: only appearance changes (or Restore Defaults) redraw every icon.
    @Test func onlyAppearanceChangesRedrawIcons() {
        #expect(Icons.redraws(after: nil))
        #expect(Icons.redraws(after: "appearance") && Icons.redraws(after: "appearancePreferences"))
        for key in ["showHidden", "session", "placesWidth", "perFolder", "statusBarMode"] { #expect(!Icons.redraws(after: key), "\(key)") }
    }

    // B9: in a cloud folder the capacity bar (showing the account's quota) opens the account's storage page.
    @Test func capacityBarOpensTheStorageThatItShows() {
        let previous = CloudAccounts.shared.backend
        let id = UUID().uuidString.lowercased()
        CloudAccounts.shared.backend = DemoCloudBackend(accounts: [
            CloudAccount(id: "acct", email: "me@example.com", displayName: "Me"),
            CloudAccount(id: id, provider: .dropbox, email: "me@example.com", displayName: "Me"),
        ])
        defer { CloudAccounts.shared.backend = previous }
        let drive = ViewContainer.storagePage(for: URL(string: "gdrive://acct/my-drive/")!)
        #expect(drive.host == "drive.google.com" && drive.path == "/settings/storage" && drive.query?.contains("authuser=me@example.com") == true)
        #expect(ViewContainer.storagePage(for: URL(string: "dropbox://\(id)/")!).absoluteString == "https://www.dropbox.com/account/plan")
        #expect(ViewContainer.storagePage(for: URL(fileURLWithPath: NSHomeDirectory())).scheme == "x-apple.systempreferences")
        #expect(ViewContainer.storagePage(for: URL(string: "gdrive://gone/my-drive/")!).scheme == "x-apple.systempreferences")
    }
}
