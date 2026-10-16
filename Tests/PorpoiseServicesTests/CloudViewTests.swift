import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

/// How Drive folders show: who owns what, Shared with me newest first; shown, never saved as anyone's style.
@MainActor @Suite(.isolatedSettings) struct CloudViewTests {
    let shared = URL(string: "gdrive://00000000-0000-0000-0000-000000000001/shared-with-me/")!
    let folder = URL(string: "gdrive://00000000-0000-0000-0000-000000000001/my-drive/abc/")!

    @Test func sharedWithMeListsNewestSharedFirstWithOwners() {
        let m = DirectoryModel(location: shared)
        #expect(m.props.mode == .details && m.props.sortRole == .sharedTime && m.props.sortOrder == .descending && !m.props.foldersFirst)
        #expect(Array(m.props.roles(for: .details).prefix(2)) == [.owner, .sharedTime])
        // Saving keeps the user's own style: no Owner column or Shared sorting leaks into it.
        m.saveProps()
        let saved = Settings.shared.viewProperties(for: URL(fileURLWithPath: "/tmp"))
        #expect(saved.mode == .icons && saved.sortRole == .name && !saved.roles(for: .details).contains(.owner))
    }

    @Test func otherDriveFoldersGetAnOwnerColumnOnly() {
        let m = DirectoryModel(location: folder)
        #expect(m.props.roles(for: .details).first == .owner && m.props.sortRole == .name && m.props.mode == .icons)
        m.setLocation(URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(!m.props.roles(for: .details).contains(.owner))
        m.setLocation(shared)
        m.reloadProps()
        #expect(m.props.sortRole == .sharedTime)
    }

    @Test func aChangeTheUserMakesIsTheirs() {
        let m = DirectoryModel(location: shared)
        var p = m.props
        p.sortRole = .name
        m.props = p
        m.saveProps()
        #expect(Settings.shared.viewProperties(for: shared).sortRole == .name)
    }

    @Test func sharedDatesSortGroupAndShow() {
        let now = Date()
        let new = FileItem(url: URL(string: "gdrive://a/x/2/")!, name: "new", isDirectory: false, sharedDate: now)
        #expect(ItemGrouper.groupName(new, role: .sharedTime, now: now) == "Today")
        #expect(new.date(for: .sharedTime) == now && new.date(for: .name) == nil)
        #expect(ItemRole.sharedTime.title == "Shared" && ItemRole.otherRoles.contains(.sharedTime))
        #expect(ItemRole.sharedTime.orderLabels.descending == "Newest First")
        let m = DirectoryModel(location: shared)
        #expect(!m.text(for: .sharedTime, of: new).isEmpty)
        let doc = FileItem(url: URL(string: "gdrive://a/x/3/")!, name: "Notes", isDirectory: false, contentType: "com.google.apps.document")
        #expect(doc.isWebDocument && m.text(for: .size, of: doc) == "—" && !new.isWebDocument)
    }
}
