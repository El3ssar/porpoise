import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

/// Cloud metadata remains available without imposing a display style over the user's settings.
@MainActor @Suite(.isolatedSettings) struct CloudViewTests {
    let shared = URL(string: "gdrive://00000000-0000-0000-0000-000000000001/shared-with-me/")!
    let folder = URL(string: "gdrive://00000000-0000-0000-0000-000000000001/my-drive/abc/")!

    @Test func cloudFoldersUseAndSaveTheCommonStyle() {
        var common = ViewProperties(); common.mode = .compact; common.sortRole = .size
        Settings.shared.save(common, for: URL(fileURLWithPath: "/tmp"))
        let m = DirectoryModel(location: shared)
        #expect(m.props == common)
        m.props.mode = .icons
        m.saveProps()
        #expect(DirectoryModel(location: folder).props.mode == .icons)
        #expect(DirectoryModel(location: URL(fileURLWithPath: "/tmp")).props.mode == .icons)
    }

    @Test func cloudFoldersRememberTheirOwnStyle() {
        Settings.shared.rememberPerFolder = true
        let m = DirectoryModel(location: shared)
        m.props.mode = .compact
        m.props.setRoles([.owner, .sharedTime], for: .details)
        m.saveProps()
        #expect(DirectoryModel(location: shared).props == m.props)
        #expect(DirectoryModel(location: folder).props == ViewProperties())
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
