import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// DirectoryModel on remote and virtual locations (a phone played by a recording adb, a tag nobody uses), and the
/// corners of local listings: an expanded folder that vanished, a media folder already in Icons, duplicate rows.
@MainActor @Suite(.isolatedSettings) struct DirectoryModelCoverageTests {
    let fm = FileManager.default

    static let listing = """
        total 24
        drwxrwx--x  4 root sdcard_rw 3452 2024-05-01 10:12 .
        drwxrwx--x  4 root sdcard_rw 3452 2024-05-01 10:12 ..
        drwxrws---  2 u0_a1 media_rw 3452 2025-02-03 08:00 DCIM
        -rw-rw----  1 u0_a1 media_rw 2048 2025-02-03 08:01 photo.jpg

        """

    // MARK: Remote locations

    @Test func remoteFoldersListThroughTheirProvider() async throws {
        let adb = try RecordingTool()
        let serial = "COV" + UUID().uuidString.prefix(8).filter(\.isLetter).uppercased() + "X"
        let root = URL(string: "adb://\(serial)/")!
        RemoteFS.use(ADBProvider(serial: serial, adb: adb.path), for: root)
        defer { RemoteFS.use(nil, for: root) }
        try adb.reply(Self.listing)

        var loads = 0
        let m = try await DirectoryModel.loaded(root) {
            $0.props.mode = .details
            $0.onLoaded = { loads += 1 }
        }
        #expect(m.kind == .device && m.loadError == nil && loads == 1)
        #expect(m.rowNames == ["DCIM", "photo.jpg"])

        // An expanded remote folder is listed by the provider too, and again on every reload.
        let dcim = try #require(m.rows.first { $0.item.name == "DCIM" }?.item.url)
        m.setExpanded(dcim, true)
        #expect(await eventually { m.rows.count == 4 })
        m.selection = [dcim, root.appendingPathComponent("sdcard/gone.txt")]
        m.reload()
        #expect(await eventually { !m.isLoading })
        #expect(m.rows.count == 4 && m.rows.filter { $0.depth == 1 }.count == 2)
        #expect(m.selection == [dcim])  // what's no longer there is no longer selected

        // The device went away: the error is shown, nothing is listed.
        try adb.reply("", status: 1)
        m.reload()
        #expect(await eventually { !m.isLoading })
        #expect(m.loadError != nil && m.rows.isEmpty)
    }

    // MARK: Virtual locations

    @Test func aTagNobodyUsesListsNothing() async throws {
        let m = try await DirectoryModel.loaded(FinderTags.url(for: "porpoise-coverage-\(UUID().uuidString)"), timeout: 60)
        #expect(m.kind.isVirtual && m.items.isEmpty && m.rows.isEmpty && m.loadError == nil)
        #expect(m.props.mode == .icons && m.props.sortRole == .name)
    }

    /// Sorted by tags, search results aren't sorted off the main thread first (tags are read while showing them).
    @Test func searchResultsSortedByTagsShowAtOnce() async throws {
        let s = try Scratch()
        let a = try #require(FileItem.load(try s.file("a.txt"))), b = try #require(FileItem.load(try s.file("b.txt")))
        let m = try await DirectoryModel.loaded(s.url)
        m.props.sortRole = .tags
        var shown = false
        m.sortSearchResults([b, a]) { apply in
            apply(); shown = true
        }
        #expect(shown && m.isSearching && m.rows.count == 2)
    }

    /// Recent Locations lists the folders visited (one deleted since is left out).
    @Test func recentLocationsListVisitedFolders() async throws {
        let s = try Scratch()
        let kept = try s.folder("kept"), gone = try s.folder("gone")
        RecentLocations.shared.visit(gone)
        RecentLocations.shared.visit(kept)
        try fm.removeItem(at: gone)
        let m = try await DirectoryModel.loaded(PlacesModel.recentLocationsURL)
        #expect(m.items.contains { $0.url == kept })
        #expect(!m.items.contains { $0.url == gone })
    }

    // MARK: Local corners

    @Test func anExpandedFolderThatVanishedListsNothing() async throws {
        let s = try Scratch()
        try s.file("sub/child.txt"); try s.file("top.txt")
        let m = try await DirectoryModel.loaded(s.url) { $0.props.mode = .details }
        m.setExpanded(s.path("sub"), true)
        #expect(await eventually { m.rowNames.contains("child.txt") })
        try fm.removeItem(at: s.path("sub"))
        m.reload()
        #expect(await eventually { !m.isLoading && m.rowNames == ["top.txt"] })
    }

    @Test func anUnreadableFolderExpandsToNothing() async throws {
        let s = try Scratch()
        try s.file("locked/secret.txt")
        chmod(s.path("locked").path, 0o000)
        defer { chmod(s.path("locked").path, 0o755) }
        let m = try await DirectoryModel.loaded(s.url) { $0.props.mode = .details }
        let locked = try #require(m.rows.first?.item.url)
        var changes = 0
        m.onChange = { changes += 1 }
        m.setExpanded(locked, true)
        let shown = changes
        #expect(await eventually { changes > shown })  // its listing came back (empty)
        #expect(m.rowNames == ["locked"] && m.rows.first?.isExpanded == true)
    }

    /// "Icons for media folders" has nothing to do in a media folder already shown as icons with previews.
    @Test func aMediaFolderAlreadyInIconsStaysAsItIs() async throws {
        let s = try Scratch()
        for n in ["a.jpg", "b.png", "c.mov", "d.txt"] { try s.file(n) }
        Settings.shared.dynamicView = true
        var p = ViewProperties(); p.mode = .icons; p.previews = true; p.sortRole = .size
        ViewStyleStore().save(p, for: s.url)
        let m = try await DirectoryModel.loaded(s.url)
        #expect(m.props.mode == .icons && m.props.previews && m.props.sortRole == .size)
        m.saveProps()
        #expect(ViewStyleStore().style(for: s.url).mode == .icons)
    }

    /// The same item twice (a search can find it along two paths): rows are found by URL and by path all the same.
    @Test func duplicateRowsAreFoundByTheirFirstRow() async throws {
        let s = try Scratch()
        let f = try s.file("sub/x.txt")
        let it = try #require(FileItem.load(f))
        let m = try await DirectoryModel.loaded(s.url)
        m.searchResults = [it, it]
        #expect(m.rows.count == 2)
        #expect(m.index(of: f) == 0)
        #expect(m.index(of: s.url.appendingPathComponent("sub/../sub/x.txt")) == 0)
        #expect(m.index(of: s.path("nope")) == nil)
    }

    @Test func textForMissingOwnerGroupAndLinkIsEmpty() throws {
        let s = try Scratch()
        let m = DirectoryModel(location: s.url)
        let it = FileItem(url: URL(fileURLWithPath: "/x/y"), name: "y", isDirectory: false)
        for role in [ItemRole.owner, .group, .linkDestination] { #expect(m.text(for: role, of: it).isEmpty) }
    }
}
