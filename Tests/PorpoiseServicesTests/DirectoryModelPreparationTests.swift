import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings) struct DirectoryModelPreparationTests {
    func files(_ root: URL, count: Int = 2001) -> [FileItem] {
        (0..<count).reversed().map {
            FileItem(url: root.appendingPathComponent("file\($0).txt"), name: "file\($0).txt", isDirectory: false, size: Int64($0))
        }
    }

    @Test func geometryChangesKeepTheRowsAndOrderWhileExpansionStillRebuilds() throws {
        let s = try Scratch()
        let m = DirectoryModel(location: s.url)
        let folder = FileItem(url: s.path("folder"), name: "folder", isDirectory: true)
        m.applyEdit(ListingEdit(folder: s.url, added: [folder] + files(s.url, count: 12)))
        let revision = m.rowsRevision
        let names = m.rows.map(\.item.name)
        var changes = 0
        m.onChange = { changes += 1 }
        for mode in [ViewMode.details, .compact, .icons] { m.props.mode = mode }
        m.props.setIconSize(90, for: .icons)
        #expect(m.rowsRevision == revision && m.rows.map(\.item.name) == names)
        #expect(changes >= 3)
        m.props.mode = .details
        m.setExpanded(folder.url, true)
        let expandedRevision = m.rowsRevision
        m.props.mode = .icons
        #expect(m.rowsRevision > expandedRevision)
        #expect(m.rows.allSatisfy { !$0.isExpanded })
        m.props.sortOrder = .descending
        #expect(m.rows.map(\.item.name) != names)
    }

    @Test func latestPreparationWinsAfterEditsFilterAndSortChanges() throws {
        let s = try Scratch()
        let m = DirectoryModel(location: s.url)
        var pending: [(DirectoryModelPreparation, (DirectoryModelPreparation.Result) -> Void)] = []
        m.prepareRows = { input, done in
            pending.append((input, done)); return LocationLoad()
        }
        m.applyEdit(ListingEdit(folder: s.url, added: files(s.url)))
        #expect(m.isLoading && m.rows.isEmpty)
        m.filter = NameFilter(text: "file10")
        m.props.sortOrder = .descending
        let removed = s.path("file100.txt")
        m.applyEdit(ListingEdit(folder: s.url, removed: [removed]))
        #expect(pending.count == 4)
        for request in pending.dropLast() { request.1(try #require(request.0.build())) }
        #expect(m.isLoading && m.rows.isEmpty)
        m.selection = [removed, s.path("file1099.txt")]
        m.currentURL = removed
        let latest = try #require(pending.last)
        latest.1(try #require(latest.0.build()))
        #expect(!m.isLoading && !m.rows.isEmpty)
        #expect(m.selection == [s.path("file1099.txt")] && m.currentURL == nil)
        #expect(m.rows.allSatisfy { $0.item.name.contains("file10") && $0.item.url != removed })
        #expect(m.rows.first?.item.name == "file1099.txt")
        #expect(m.rows.last?.item.name == "file10.txt")
        #expect(m.index(of: s.path("file1099.txt")) == 0)
        #expect(m.identity(ofRow: 0) == FilePath.key(s.path("file1099.txt")))
    }

    @Test func navigationAndSearchDiscardAnOlderLocalPreparation() async throws {
        let s = try Scratch()
        let other = try s.folder("other")
        let m = DirectoryModel(location: s.url)
        var pending: [(DirectoryModelPreparation, (DirectoryModelPreparation.Result) -> Void)] = []
        m.prepareRows = { input, done in
            pending.append((input, done)); return LocationLoad()
        }
        m.applyEdit(ListingEdit(folder: s.url, added: files(s.url)))
        m.searchResults = [FileItem(url: s.path("search.txt"), name: "search.txt", isDirectory: false)]
        pending[0].1(try #require(pending[0].0.build()))
        #expect(m.rows.map(\.item.name) == ["search.txt"] && !m.isLoading)
        m.searchResults = nil
        #expect(pending.count == 2)
        m.setLocation(other)
        try #require(await eventually { !m.isLoading })
        pending[1].1(try #require(pending[1].0.build()))
        #expect(m.location == other && m.rows.isEmpty && !m.isLoading)
    }

    @Test func loadedNotificationWaitsForPreparedRowsAndSelectionSurvives() async throws {
        let s = try Scratch()
        for i in 0..<2001 { try s.file("file\(i).txt") }
        let m = DirectoryModel(location: s.url)
        var pending: [(DirectoryModelPreparation, (DirectoryModelPreparation.Result) -> Void)] = []
        m.prepareRows = { input, done in
            pending.append((input, done)); return LocationLoad()
        }
        let selected = s.path("file12.txt")
        m.selection = [selected]
        m.currentURL = selected
        var loaded = 0
        defer { m.onLoaded = nil }
        m.onLoaded = {
            loaded += 1; #expect(!m.isLoading && m.rows.count == 2001)
        }
        m.reload()
        try #require(await eventually { !pending.isEmpty })
        #expect(m.isLoading && loaded == 0)
        let stale = try #require(pending.last)
        m.reload()
        stale.1(try #require(stale.0.build()))
        #expect(m.isLoading && loaded == 0)
        try #require(await eventually { pending.count >= 2 })
        let latest = try #require(pending.last)
        latest.1(try #require(latest.0.build()))
        #expect(!m.isLoading && loaded == 1 && m.selection == [selected] && m.currentURL == selected)
    }

    @Test func snapshotPreservesHiddenBackupsGroupingAndExpandedChildren() throws {
        let s = try Scratch()
        let folder = FileItem(url: s.path("folder"), name: "folder", isDirectory: true)
        let top =
            [folder]
            + ["file10.txt", "file2.txt", ".hidden", "backup~"].map {
                FileItem(url: s.path($0), name: $0, isDirectory: false, isHidden: $0.hasPrefix("."))
            }
        var props = ViewProperties()
        props.mode = .details
        props.groupRole = .type
        props.groupSameAsSort = false
        let child = FileItem(url: s.path("folder/child.txt"), name: "child.txt", isDirectory: false)
        let input = DirectoryModelPreparation(
            items: top, incoming: [], children: [folder.url: [child]], expanded: [folder.url], props: props, filter: NameFilter(),
            choice: .natural, hideBackups: true, sizes: [:], knownTags: [:], ordered: nil)
        let result = try #require(input.build())
        #expect(Set(result.rows.map(\.item.name)) == ["folder", "child.txt", "file2.txt", "file10.txt"])
        #expect(result.rows.first(where: { $0.item.url == folder.url })?.isExpanded == true)
        #expect(result.rows.first(where: { $0.item.url == child.url })?.depth == 1)
        #expect(!result.groups.isEmpty && result.rows.allSatisfy { $0.group >= 0 })
        #expect(result.keys.count == result.rows.count)
        #expect(input.build(cancelled: { true }) == nil)
    }
    @Test func productionQueueCancelsPublicationAndReadsTagsOnItsWorker() async throws {
        let s = try Scratch()
        let a = try s.file("a.txt"), b = try s.file("b.txt")
        FinderTags.set(["Red"], on: b)
        var props = ViewProperties()
        props.sortRole = .tags
        props.groupRole = .tags
        props.groupSameAsSort = false
        let input = DirectoryModelPreparation(
            items: [try #require(FileItem.load(a)), try #require(FileItem.load(b))], incoming: [], children: [:], expanded: [],
            props: props, filter: NameFilter(), choice: .natural, hideBackups: false, sizes: [:], knownTags: [:], ordered: nil)
        var cancelledPublications = 0
        let cancelled = DirectoryModelPreparation.start(input) { _ in cancelledPublications += 1 }
        cancelled.cancel()
        var completed: DirectoryModelPreparation.Result?
        let live = DirectoryModelPreparation.start(input) { result in
            #expect(Thread.isMainThread)
            completed = result
        }
        defer { live.cancel() }
        try #require(await eventually { completed != nil })
        #expect(cancelledPublications == 0)
        let result = try #require(completed)
        #expect(result.rows.first?.item.url == b)
        #expect(result.tags[b]?.map(\.name) == ["Red"])
        #expect(result.groups.contains { $0.title == "Red" })
        var checks = 0
        #expect(
            input.build(cancelled: {
                checks += 1; return checks > 1
            }) == nil)
    }

    @Test func realLargePreparationPublishesAnOptimisticReplacementWithoutLosingSelection() async throws {
        let s = try Scratch()
        let m = DirectoryModel(location: s.url)
        let original = files(s.url)
        m.applyEdit(ListingEdit(folder: s.url, added: original))
        try #require(await eventually { !m.isLoading && m.rows.count == original.count })
        let chosen = s.path("file3.txt")
        m.selection = [chosen]
        let replacement = FileItem(url: chosen, name: "renamed.txt", isDirectory: false, size: 99)
        m.applyEdit(ListingEdit(folder: s.url, replaced: [replacement]))
        try #require(await eventually { !m.isLoading && m.rows.contains { $0.item.name == "renamed.txt" } })
        #expect(m.selection == [chosen] && m.selectedItems.first?.size == 99)
        m.filter = NameFilter(text: "renamed")
        try #require(await eventually { !m.isLoading && m.rows.count == 1 })
        #expect(m.rows.first?.item == replacement)
    }

    @Test(arguments: SortingChoice.allCases)
    func preparedRowsMatchSynchronousModelAcrossSortingAndGrouping(_ choice: SortingChoice) throws {
        let s = try Scratch()
        let names = ["Z10.log", "Z2.log", "é.md", "E.txt", ".hidden", "backup~"]
        var items: [FileItem] = []
        for (index, name) in names.enumerated() {
            let url = try s.file(name, String(repeating: "x", count: index + 1))
            items.append(try #require(FileItem.load(url)))
        }
        let folder = try s.folder("folder")
        items.append(try #require(FileItem.load(folder)))
        FinderTags.set(["Red"], on: s.path("Z2.log"))
        Settings.shared.sortingChoice = choice
        Settings.shared.hideBackupFiles = true
        for role in [ItemRole.name, .size, .extension_, .tags] {
            for order in [SortOrder.ascending, .descending] {
                let reference = DirectoryModel(location: s.url)
                var props = ViewProperties()
                props.mode = .details
                props.sortRole = role
                props.sortOrder = order
                props.groupRole = role
                props.groupSameAsSort = false
                reference.props = props
                reference.applyEdit(ListingEdit(folder: s.url, added: items))
                reference.filter = NameFilter(text: "")
                let input = DirectoryModelPreparation(
                    items: items, incoming: [], children: [:], expanded: [], props: props, filter: reference.filter,
                    choice: choice, hideBackups: true, sizes: [:], knownTags: [:], ordered: nil)
                let prepared = try #require(input.build())
                #expect(prepared.rows.map(\.item) == reference.rows.map(\.item))
                #expect(prepared.rows.map(\.group) == reference.rows.map(\.group))
                #expect(prepared.groups.map(\.title) == reference.groups.map(\.title))
            }
        }
    }

}
