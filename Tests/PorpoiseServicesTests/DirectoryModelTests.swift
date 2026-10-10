import Foundation
import Testing
@testable import PorpoiseCore
@testable import PorpoiseServices
import PorpoiseTestSupport

/// DirectoryModel on real folders: loads finish on the main queue, so the tests wait for them (bounded).
@MainActor @Suite(.isolatedSettings) struct DirectoryModelTests {
    let fm = FileManager.default

    /// A model showing `url`, after its first load.
    private func loaded(_ url: URL, _ setUp: (DirectoryModel) -> Void = { _ in }) async throws -> DirectoryModel {
        let m = DirectoryModel(location: url)
        setUp(m)
        m.reload()
        try #require(await eventually { !m.isLoading })
        return m
    }

    private func names(_ m: DirectoryModel) -> [String] { m.rows.map(\.item.name) }

    private func setDate(_ url: URL, daysAgo: Double) throws {
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86400)], ofItemAtPath: url.path)
    }

    // MARK: Loading

    @Test func loadsAFolderFoldersFirstInNaturalOrder() async throws {
        let s = try Scratch()
        try s.file("file10.txt"); try s.file("file2.txt"); try s.file("File1.txt")
        try s.folder("zeta"); try s.folder("Alpha")
        var loads = 0
        let m = try await loaded(s.url) { $0.onLoaded = { loads += 1 } }
        #expect(names(m) == ["Alpha", "zeta", "File1.txt", "file2.txt", "file10.txt"])
        #expect(loads >= 1)   // FSEvents may report the files just made: another (quiet) reload
        #expect(m.loadError == nil && !m.blockedByPrivacy)
        #expect(m.visibleCounts.folders == 2 && m.visibleCounts.files == 3)
        #expect(m.rows.allSatisfy { $0.depth == 0 && $0.group == -1 })
    }

    @Test func hiddenAndBackupFiles() async throws {
        let s = try Scratch()
        try s.file("shown"); try s.file(".dotfile"); try s.file("notes.txt~")
        let flagged = try s.file("flagged")
        try run("/usr/bin/chflags", ["hidden", flagged.path])
        let m = try await loaded(s.url)
        #expect(names(m) == ["notes.txt~", "shown"])
        m.props.showHidden = true
        #expect(names(m) == [".dotfile", "flagged", "notes.txt~", "shown"])
        Settings.shared.hideBackupFiles = true
        m.rebuild()
        #expect(names(m) == [".dotfile", "flagged", "notes.txt~", "shown"])   // hidden files shown: backups too
        m.props.showHidden = false
        #expect(names(m) == ["shown"])
        // Hidden items come last when asked.
        m.props.showHidden = true
        m.props.hiddenLast = true
        Settings.shared.hideBackupFiles = false
        m.rebuild()
        #expect(names(m) == ["notes.txt~", "shown", ".dotfile", "flagged"])
    }

    @Test func sortRolesAndOrders() async throws {
        let s = try Scratch()
        try setDate(s.file("small.txt", "1"), daysAgo: 1)
        try setDate(s.file("big.log", String(repeating: "x", count: 300)), daysAgo: 3)
        try setDate(s.file("medium.md", String(repeating: "x", count: 20)), daysAgo: 2)
        try s.folder("dir")
        let m = try await loaded(s.url)
        m.props.sortRole = .size
        #expect(names(m) == ["dir", "small.txt", "medium.md", "big.log"])
        m.props.sortOrder = .descending
        #expect(names(m) == ["dir", "big.log", "medium.md", "small.txt"])   // folders stay first
        m.props.foldersFirst = false
        m.props.sortRole = .modificationTime
        m.props.sortOrder = .ascending
        #expect(names(m).filter { $0 != "dir" } == ["big.log", "medium.md", "small.txt"])
        #expect(names(m).last == "dir")   // created just now
        m.props.sortRole = .extension_
        #expect(names(m) == ["dir", "big.log", "medium.md", "small.txt"])
    }

    @Test func sortingChoiceFromSettings() async throws {
        let s = try Scratch()
        for n in ["b2", "a10", "a9", "B1"] { try s.file(n) }
        let m = try await loaded(s.url)
        #expect(names(m) == ["a9", "a10", "B1", "b2"])
        Settings.shared.sortingChoice = .caseSensitive
        m.rebuild()
        #expect(names(m) == ["B1", "a10", "a9", "b2"])
    }

    @Test func groupsKeepFoldersApart() async throws {
        let s = try Scratch()
        try s.file("apple"); try s.file("avocado"); try s.file("banana"); try s.file("7up")
        try s.folder("archive")
        let m = try await loaded(s.url)
        m.props.groupRole = .name
        #expect(m.groups.map(\.title) == ["A", "0 - 9", "A", "B"])
        #expect(m.groups.map(\.count) == [1, 1, 2, 1])
        #expect(m.rows.map(\.group) == [0, 1, 2, 2, 3])
        m.props.groupRole = nil
        #expect(m.groups.isEmpty)
        // "Group by sort role" follows the sort.
        m.props.sortRole = .size
        m.props.groupSameAsSort = true
        #expect(m.groups.map(\.title) == ["Folders", "Small"])
    }

    @Test func nameFilter() async throws {
        let s = try Scratch()
        for n in ["Report.pdf", "report.txt", "a1", "a22", "notes.txt"] { try s.file(n) }
        let m = try await loaded(s.url)
        m.filter = NameFilter(text: "rep")
        #expect(names(m) == ["Report.pdf", "report.txt"])
        m.filter = NameFilter(text: "rep", caseSensitive: true)
        #expect(names(m) == ["report.txt"])
        m.filter = NameFilter(text: "*.txt", mode: .glob)
        #expect(names(m) == ["notes.txt", "report.txt"])
        m.filter = NameFilter(text: "^a\\d$", mode: .regex)
        #expect(names(m) == ["a1"])
        // An expression still being typed doesn't empty the view.
        m.filter = NameFilter(text: "a(", mode: .regex)
        #expect(m.rows.count == 5)
        m.filter = NameFilter()
        #expect(m.rows.count == 5)
    }

    /// Typing in the filter bar narrows the sorted list; whatever changes the order still applies under a filter.
    @Test func filteringKeepsTheOrderAndFollowsChanges() async throws {
        let s = try Scratch()
        for (n, size) in [("a.txt", 30), ("b.txt", 10), ("c.log", 20), ("d.txt", 40)] { try s.file(n, String(repeating: "x", count: size)) }
        let m = try await loaded(s.url)
        m.props.sortRole = .size
        m.filter = NameFilter(text: "txt")
        #expect(names(m) == ["b.txt", "a.txt", "d.txt"])
        m.props.sortOrder = .descending
        #expect(names(m) == ["d.txt", "a.txt", "b.txt"])
        m.filter = NameFilter(text: ".t")
        #expect(names(m) == ["d.txt", "a.txt", "b.txt"])
        // A file that appears while filtering takes its place in the order.
        try s.file("e.txt", String(repeating: "x", count: 35))
        #expect(await eventually { names(m) == ["d.txt", "e.txt", "a.txt", "b.txt"] })
        m.filter = NameFilter()
        #expect(names(m) == ["d.txt", "e.txt", "a.txt", "c.log", "b.txt"])
    }

    /// Drawing never waits for tags or cloud states: they're read in the background, then the view is told.
    @Test func drawingReadsItemMetadataInTheBackground() async throws {
        let s = try Scratch()
        let tagged = try s.file("tagged.txt")
        FinderTags.set(["Red"], on: tagged)
        let m = try await loaded(s.url)
        var loaded = 0
        m.onMetadataLoaded = { loaded += 1 }
        let item = try #require(m.rows.first?.item)
        #expect(m.shownTags(for: item).isEmpty)          // not read yet
        #expect(m.shownCloud(for: item).state == .local)
        #expect(await eventually { loaded == 1 })
        #expect(m.shownTags(for: item).map(\.name) == ["Red"])
        // Re-reading cloud states keeps what's known meanwhile, and tags stay cached.
        m.refreshCloud()
        #expect(m.shownTags(for: item).map(\.name) == ["Red"])
        #expect(await eventually { loaded == 2 })
        // Tagging clears the tags, which are then read again.
        FinderTags.set([], on: tagged)
        m.refreshTags()
        _ = m.shownTags(for: item)
        #expect(await eventually { loaded == 3 && m.shownTags(for: item).isEmpty })
    }

    /// Reading for drawing that finishes after the folder changed is dropped.
    @Test func metadataOfAnEarlierLoadIsDropped() async throws {
        let s = try Scratch()
        let tagged = try s.file("tagged.txt")
        FinderTags.set(["Red"], on: tagged)
        let m = try await loaded(s.url)
        var loaded = 0
        m.onMetadataLoaded = { loaded += 1 }
        let item = try #require(m.rows.first?.item)
        _ = m.shownTags(for: item)
        m.reload()
        try #require(await eventually { !m.isLoading })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(loaded == 0)
    }

    // MARK: Selection across reloads

    @Test func selectionKeepsWhatStillExists() async throws {
        let s = try Scratch()
        let a = try s.file("a"), b = try s.file("b")
        let m = try await loaded(s.url)
        var changes = 0
        m.onSelectionChanged = { changes += 1 }
        m.selection = [a, b]
        m.currentURL = b
        #expect(m.selectedItems.map(\.name) == ["a", "b"] && m.selectedCounts.files == 2)
        try fm.removeItem(at: b)
        m.reload()
        #expect(await eventually { !m.isLoading && m.rows.count == 1 })
        #expect(m.selection == [a])
        #expect(m.currentURL == nil)
        #expect(changes == 2)
    }

    @Test func leavingAFolderClearsItsState() async throws {
        let s = try Scratch()
        let a = try s.file("one/a"); try s.file("two/b")
        let m = try await loaded(s.path("one"))
        m.selection = [a]
        m.currentURL = a
        m.setLocation(s.path("two"))
        #expect(m.selection.isEmpty && m.currentURL == nil && m.items.isEmpty)
        #expect(await eventually { !m.isLoading })
        #expect(names(m) == ["b"])
        // The same folder again is a reload: the selection stays.
        let b = s.path("two/b")
        m.selection = [b]
        m.setLocation(s.path("two"))
        #expect(await eventually { !m.isLoading })
        #expect(m.selection == [b])
    }

    // MARK: Expandable folders (Details)

    @Test func expandingAndCollapsingFolders() async throws {
        let s = try Scratch()
        try s.file("top/inner/deep.txt"); try s.file("top/child.txt"); try s.file("z.txt")
        let top = s.path("top"), inner = s.path("top/inner")
        let m = try await loaded(s.url) { $0.props.mode = .details }
        m.setExpanded(top, true)
        #expect(await eventually { names(m) == ["top", "inner", "child.txt", "z.txt"] })
        #expect(m.rows.map(\.depth) == [0, 1, 1, 0] && m.rows[0].isExpanded)
        m.setExpanded(inner, true)
        #expect(await eventually { names(m).contains("deep.txt") })
        #expect(m.rows.first { $0.item.name == "deep.txt" }?.depth == 2)

        // Collapsing the top folder collapses its subfolders, and moves the selection out of it.
        let deep = s.path("top/inner/deep.txt")
        m.selection = [deep, s.path("z.txt")]
        m.currentURL = deep
        m.setExpanded(top, false)
        #expect(names(m) == ["top", "z.txt"])
        #expect(m.expanded.isEmpty)
        #expect(m.selection == [s.path("z.txt")] && m.currentURL == top)

        // Other view modes show no tree; "Expandable folders" off drops it.
        m.toggleExpanded(top)
        #expect(await eventually { m.rows.count == 4 })
        m.props.mode = .icons
        #expect(names(m) == ["top", "z.txt"])
        m.props.mode = .details
        m.collapseAll()
        #expect(names(m) == ["top", "z.txt"] && m.expanded.isEmpty)
    }

    /// A folder expanded while a reload runs: its own listing may arrive first, and the reload (which didn't know it
    /// was expanded) must not throw it away.
    @Test func expandingDuringAReloadKeepsTheChildren() async throws {
        let s = try Scratch()
        for i in 0..<400 { try s.file("file\(i)") }   // a slower reload than the expanded folder's listing
        try s.file("sub/child")
        let sub = s.path("sub")
        let m = try await loaded(s.url) { $0.props.mode = .details }
        for _ in 0..<5 {
            m.reload()
            m.setExpanded(sub, true)
            try #require(await eventually { !m.isLoading && names(m).contains("child") })
            m.setExpanded(sub, false)
        }
    }

    @Test func expandedFoldersComeBackAfterAReload() async throws {
        let s = try Scratch()
        try s.file("sub/child")
        let m = try await loaded(s.url) { $0.props.mode = .details }
        m.setExpanded(s.path("sub"), true)
        #expect(await eventually { m.rows.count == 2 })
        try s.file("sub/second")
        m.reload()
        #expect(await eventually { !m.isLoading && names(m) == ["sub", "child", "second"] })
    }

    // MARK: Live updates

    @Test func followsChangesOnDisk() async throws {
        let s = try Scratch()
        try s.file("first")
        let m = try await loaded(s.url)
        try s.file("added")
        #expect(await eventually { names(m) == ["added", "first"] })
        try fm.moveItem(at: s.path("added"), to: s.path("renamed"))
        #expect(await eventually { names(m) == ["first", "renamed"] })
        try fm.removeItem(at: s.path("first"))
        #expect(await eventually { names(m) == ["renamed"] })
    }

    @Test func followsChangesInExpandedFolders() async throws {
        let s = try Scratch()
        try s.folder("sub")
        let m = try await loaded(s.url) { $0.props.mode = .details }
        m.setExpanded(s.path("sub"), true)
        #expect(await eventually { m.rows.first?.isExpanded == true })
        try s.file("sub/new")
        #expect(await eventually { names(m) == ["sub", "new"] })
    }

    // MARK: Search results

    @Test func searchResultsReplaceTheListing() async throws {
        let s = try Scratch()
        try s.file("here/local")
        let found = try s.file("elsewhere/deep/match.txt")
        let m = try await loaded(s.path("here"))
        m.searchResults = [try #require(FileItem.load(found))]
        m.showSearchView()
        #expect(m.isSearching && names(m) == ["match.txt"])
        #expect(m.props.mode == .details && m.props.roles(for: .details).contains(.path))
        #expect(m.text(for: .path, of: m.rows[0].item) == s.path("elsewhere/deep").path)
        // A reload during the search keeps a selected result.
        m.selection = [found]
        m.reload()
        #expect(await eventually { !m.isLoading })
        #expect(m.selection == [found])
        // Closing the search: the folder's own view again.
        m.searchResults = nil
        m.endSearchView()
        #expect(m.props.mode == .icons && names(m) == ["local"])
    }

    // MARK: Errors

    @Test func unreadableFolder() async throws {
        let s = try Scratch()
        let locked = try s.folder("locked")
        try s.file("locked/secret")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let m = try await loaded(locked)
        #expect(m.loadError == "You don't have permission to view this folder.")
        #expect(!m.blockedByPrivacy && m.rows.isEmpty)
        // Going somewhere readable clears the error.
        m.setLocation(s.url)
        #expect(await eventually { !m.isLoading })
        #expect(m.loadError == nil && names(m) == ["locked"])
    }

    @Test func missingFolder() async throws {
        let s = try Scratch()
        let m = try await loaded(s.path("gone"))
        #expect(m.loadError == "Could not open “gone”.")
        #expect(m.rows.isEmpty && !m.blockedByPrivacy)
    }

    // MARK: Text shown for items

    @Test func columnTexts() async throws {
        let s = try Scratch()
        let file = try s.file("doc.txt", "hello")
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try s.file("sub/a"); try s.file("sub/.b")
        try s.symlink("link", to: "doc.txt")
        let m = try await loaded(s.url)
        let doc = try #require(m.rows.first { $0.item.name == "doc.txt" }?.item)
        let sub = try #require(m.rows.first { $0.item.name == "sub" }?.item)
        let link = try #require(m.rows.first { $0.item.name == "link" }?.item)
        #expect(m.text(for: .name, of: doc) == "doc.txt")
        #expect(m.text(for: .size, of: doc) == "5 B")
        #expect(m.text(for: .extension_, of: doc) == "txt")
        #expect(m.text(for: .permissions, of: doc) == "-rw-r-----")
        Settings.shared.permissionStyle = .numeric
        #expect(m.text(for: .permissions, of: doc) == "640")
        Settings.shared.permissionStyle = .combined
        #expect(m.text(for: .permissions, of: doc) == "-rw-r----- (640)")
        #expect(m.text(for: .owner, of: doc) == NSUserName())
        #expect(!m.text(for: .group, of: doc).isEmpty)
        #expect(m.text(for: .linkDestination, of: link) == "doc.txt")
        #expect(m.text(for: .modificationTime, of: doc).hasPrefix("Today"))
        Settings.shared.dateStyle = .absolute
        #expect(!m.text(for: .modificationTime, of: doc).hasPrefix("Today"))
        #expect(m.text(for: .type, of: sub) == "Folder")
        #expect(m.text(for: .tags, of: doc) == "")
        #expect(m.cloud(for: doc) == (CloudState.local, false))
        m.refreshCloud()
        #expect(m.cloud(for: doc).isCloud == false)
        // Folders show their item count once counted (hidden items only while shown).
        #expect(await eventually { m.text(for: .size, of: sub) == "1 item" })
        m.props.showHidden = true
        #expect(await eventually { m.text(for: .size, of: sub) == "2 items" })
        Settings.shared.folderSizeMode = .contentSize
        m.resetFolderSizes()
        #expect(await eventually { m.text(for: .size, of: sub) == "0 B" })
        Settings.shared.folderSizeMode = .none
        m.resetFolderSizes()
        #expect(m.text(for: .size, of: sub) == "")
    }

    @Test func namesWithoutExtensions() async throws {
        let s = try Scratch()
        try s.file("photo.jpeg"); try s.file(".profile"); try s.folder("folder.d")
        let m = try await loaded(s.url) { $0.props.showHidden = true }
        Settings.shared.showAllExtensions = false
        let shown = m.rows.map { m.displayName(for: $0.item) }
        #expect(shown == ["folder.d", ".profile", "photo"])
    }

    @Test func rowsAreFoundByEquivalentPaths() async throws {
        let s = try Scratch()
        try s.file("a"); try s.file("sub/b")
        let m = try await loaded(s.url)
        #expect(m.index(of: s.path("sub")) == 0 && m.index(of: s.path("a")) == 1)
        #expect(m.index(of: URL(fileURLWithPath: s.url.path + "/sub/../a")) == 1)
        #expect(m.index(of: s.path("missing")) == nil)
    }

    // MARK: Display style

    @Test func savedStyleIsTheFoldersOwn() async throws {
        let s = try Scratch()
        try s.file("a")
        Settings.shared.rememberPerFolder = true
        let m = try await loaded(s.url)
        var changed = 0
        m.onPropsChanged = { changed += 1 }
        m.props.mode = .compact
        m.saveProps()
        #expect(changed == 1)
        #expect(Settings.shared.viewProperties(for: s.url).mode == .compact)
        #expect(DirectoryModel(location: s.url).props.mode == .compact)
        m.props.mode = .details
        m.reloadProps()
        #expect(m.props.mode == .compact)
    }

    /// "Icons for media folders" is shown, never saved.
    @Test func mediaFoldersShowIconsWithoutSavingThem() async throws {
        let s = try Scratch()
        for n in ["a.jpg", "b.png", "c.mov", "d.txt"] { try s.file(n) }
        Settings.shared.dynamicView = true
        var p = ViewProperties(); p.mode = .details; p.previews = false
        Settings.shared.save(p, for: s.url)
        let m = try await loaded(s.url)
        #expect(m.props.mode == .icons && m.props.previews)
        m.props.sortRole = .size
        m.saveProps()
        let saved = Settings.shared.viewProperties(for: s.url)
        #expect(saved.mode == .details && !saved.previews && saved.sortRole == .size)
        // A later reload (a file changed) doesn't undo a mode picked meanwhile.
        m.props.mode = .compact
        m.reload()
        #expect(await eventually { !m.isLoading })
        #expect(m.props.mode == .compact)
    }

    @Test func recentLocationsHaveTheirOwnStyle() async throws {
        let m = try await loaded(PlacesModel.recentLocationsURL)
        #expect(m.isVirtual)
        #expect(m.props.mode == .details && m.props.sortRole == .name && !m.props.foldersFirst)
        #expect(m.props.roles(for: .details) == [.path, .accessTime])
        m.props.mode = .icons
        m.saveProps()   // virtual locations keep theirs
        #expect(Settings.store.object(forKey: "viewProps") == nil)
    }

    // MARK: Applications as an app library

    @Test func appLibraryListsAppsFromItsRoots() async throws {
        let s = try Scratch()
        try s.folder("Apps/Zed.app/Contents")
        try s.folder("Apps/Utilities/Tool.app/Contents")
        try s.folder("Apps/.Secret.app")
        try s.file("Apps/readme.txt")
        try s.folder("System/zed.app")       // same name as one in an earlier root: the earlier one wins
        try s.folder("System/Calculator.app")
        let saved = AppLibrary.roots
        AppLibrary.roots = [s.path("Apps"), s.path("System")]
        defer { AppLibrary.roots = saved }

        let m = try await loaded(AppLibrary.location)
        let found = m.items.map { $0.url.pathComponents.suffix(2).joined(separator: "/") }
        #expect(Set(found) == ["Apps/Zed.app", "Utilities/Tool.app", "System/Calculator.app"])
        #expect(names(m) == ["Calculator.app", "Tool.app", "Zed.app"])
        #expect(m.props == AppLibrary.props())
        #expect(AppLibrary.displayName(s.path("Apps/Zed.app")) == "Zed")
        #expect(AppLibrary.isBuiltIn(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        #expect(!AppLibrary.isBuiltIn(s.path("System/Calculator.app")))

        // Apps installed meanwhile show up.
        try s.folder("System/New.app")
        #expect(await eventually { names(m).contains("New.app") })

        // Turned off, Applications is an ordinary folder.
        Settings.shared.appLibraryView = false
        #expect(!AppLibrary.isActive(for: AppLibrary.location))
    }
}
