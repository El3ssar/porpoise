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
        #expect(DirectoryModel(location: folder).props == ViewProperties.defaults(for: folder))
    }

    @Test func locationDefaultsRespectCommonAndSavedStyles() {
        let account = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let locations: [(URL, ViewMode, ItemRole, [ItemRole])] = [
            (folder, .icons, .name, [.owner, .size, .modificationTime]),
            (shared, .details, .sharedTime, [.owner, .sharedTime, .size, .modificationTime]),
            (DropboxLocation(accountID: account, itemID: "id:folder").url, .icons, .name, [.owner, .size, .modificationTime]),
            (
                DropboxLocation(accountID: account, itemID: "collection:shared").url, .details, .sharedTime,
                [.owner, .sharedTime, .size, .modificationTime]
            ),
            (URL(string: "recent:/files")!, .details, .accessTime, [.path, .accessTime]),
            (URL(string: "recent:/locations")!, .details, .name, [.path, .accessTime]),
            (URL(string: "tags:/fixture")!, .details, .name, [.path, .accessTime]),
            (URL(string: "smart:/tmp/fixture.savedSearch")!, .details, .name, [.path, .accessTime]),
        ]
        var common = ViewProperties(); common.mode = .compact; common.sortRole = .size
        common.setRoles([.type], for: .details)
        Settings.shared.save(common, for: URL(fileURLWithPath: "/tmp"))
        for (url, mode, role, columns) in locations {
            Settings.shared.rememberPerFolder = false
            let model = DirectoryModel(location: url)
            #expect(model.props == common)
            Settings.shared.rememberPerFolder = true
            model.reloadProps()
            #expect(model.props.mode == mode && model.props.sortRole == role)
            #expect(model.props.roles(for: .details) == columns)
            let newestFirst = role == .accessTime || role == .sharedTime
            #expect(model.props.sortOrder == (newestFirst ? .descending : .ascending))
            #expect(model.props.foldersFirst == (mode != .details))
            var saved = common; saved.mode = .icons; saved.sortRole = .name
            model.props = saved; model.saveProps(); model.reloadProps()
            #expect(model.props == saved)  // no built-in column or mode overwrites an explicit choice
            #expect(Settings.shared.viewProperties(for: url, restoringDefaults: true) == ViewProperties.defaults(for: url))
            Settings.shared.rememberPerFolder = false; model.reloadProps()
            #expect(model.props == common)
        }
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
