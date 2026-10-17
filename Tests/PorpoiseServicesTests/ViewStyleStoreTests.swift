import CoreGraphics
import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore
@testable import PorpoiseServices

/// Display styles are kept where every earlier version kept them, and each location's built-in style comes from its
/// content source rather than from scheme names in Core.
@Suite(.isolatedSettings) struct ViewStyleStoreTests {
    @Test func stylesSavedByEarlierVersionsStillLoad() throws {
        // As the settings were written before the store: JSON data under "viewProps", a dictionary of path or
        // password-free URL to JSON data under "folderProps", and widths as doubles under "columnWidths".
        var common = ViewProperties(); common.mode = .compact
        var folder = ViewProperties(); folder.showHidden = true
        var server = ViewProperties(); server.mode = .details
        Settings.store.set(try JSONEncoder().encode(common), forKey: "viewProps")
        Settings.store.set(
            ["/tmp/kept": try JSONEncoder().encode(folder), "sftp://me@fixture.invalid/home/": try JSONEncoder().encode(server)],
            forKey: "folderProps")
        Settings.store.set(["name": 300.0, "size": 90.0], forKey: "columnWidths")
        let store = ViewStyleStore()
        #expect(store.style(for: URL(fileURLWithPath: "/tmp/kept")) == common)
        Settings.shared.rememberPerFolder = true
        #expect(store.style(for: URL(fileURLWithPath: "/tmp/kept")) == folder)
        #expect(store.style(for: URL(string: "sftp://me:secret@fixture.invalid/home/")!) == server)
        #expect(store.style(for: URL(fileURLWithPath: "/tmp/other")) == common)
        #expect(store.columnWidths == ["name": 300, "size": 90])
        store.columnWidths = [:]
        #expect(store.columnWidths.isEmpty && (Settings.store.dictionary(forKey: "columnWidths") as? [String: Double]) == [:])
    }

    @Test func builtInStylesComeFromEachKindOfLocation() {
        let plain = ViewProperties()
        for shared in ["gdrive://\(UUID().uuidString)/shared-with-me", "dropbox://\(UUID().uuidString)/collection:shared"] {
            let style = LocationContentSources.defaultStyle(for: URL(string: shared)!)
            #expect(style.mode == .details && style.sortRole == .sharedTime && style.sortOrder == .descending && !style.foldersFirst)
            #expect(style.roles(for: .details) == [.owner, .sharedTime] + plain.roles(for: .details))
        }
        let folder = LocationContentSources.defaultStyle(for: URL(string: "dropbox://\(UUID().uuidString)/id:abc")!)
        #expect(folder.mode == plain.mode && folder.roles(for: .details) == [.owner] + plain.roles(for: .details))
        let recent = LocationContentSources.defaultStyle(for: URL(string: "recent:/files")!)
        #expect(recent.mode == .details && recent.sortRole == .accessTime && recent.sortOrder == .descending)
        for byName in ["recent:/locations", "tags:/fixture", "smart:/tmp/fixture.savedSearch"] {
            let style = LocationContentSources.defaultStyle(for: URL(string: byName)!)
            #expect(style.sortRole == .name && style.roles(for: .details) == [.path, .accessTime] && !style.foldersFirst)
        }
        #expect(LocationContentSources.defaultStyle(for: URL(string: "sftp://fixture.invalid/")!) == plain)
        #expect(LocationKey(URL(fileURLWithPath: "/tmp")).builtIn == nil)
        #expect(LocationKey(URL(string: "sftp://me:secret@fixture.invalid/")!).stored == "sftp://me@fixture.invalid/")
    }
}
