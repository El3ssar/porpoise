import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@MainActor @Suite(.isolatedSettings) struct DirectoryRowAssemblyTests {
    @Test(arguments: [ViewMode.details, .icons], [false, true])
    func preparedAndModelRowsKeepTreeAndGroupBoundaries(mode: ViewMode, showHidden: Bool) async throws {
        let s = try Scratch("row-assembly")
        try s.folder("keep-folder/keep-nested")
        for name in [
            "keep10.txt", "keep2.log", ".keep-hidden", "keep-backup~", "other.txt",
            "keep-folder/keep-child.txt", "keep-folder/.keep-hidden", "keep-folder/keep-backup~",
            "keep-folder/other.txt", "keep-folder/keep-nested/keep-leaf.txt",
        ] { try s.file(name) }
        let folder = s.path("keep-folder"), nested = s.path("keep-folder/keep-nested")
        try FinderTags.set(["Red"], on: s.path("keep2.log"))
        Settings.shared.hideBackupFiles = true
        let model = DirectoryModel(location: s.url)
        model.props.mode = .details
        model.props.showHidden = true
        model.reload()
        try #require(await eventually { !model.isLoading })
        model.setExpanded(folder, true)
        try #require(await eventually { model.rows.contains { $0.item.url == nested } })
        model.setExpanded(nested, true)
        let leaf = s.path("keep-folder/keep-nested/keep-leaf.txt")
        try #require(await eventually { model.rows.contains { $0.item.url == leaf } })
        let original = model.items
        // Share the same realized metadata: another directory read can update access times.
        let children = [folder: model.rows.filter { $0.depth == 1 }.map(\.item), nested: model.rows.filter { $0.depth == 2 }.map(\.item)]
        for role in [nil, ItemRole.extension_, .tags] {
            for text in ["", "keep"] {
                var props = ViewProperties()
                props.mode = mode
                props.showHidden = showHidden
                props.sortRole = .name
                props.groupRole = role
                props.groupSameAsSort = false
                model.props = props
                model.filter = NameFilter(text: text)
                try #require(await eventually { !model.isLoading })
                let input = DirectoryModelPreparation(
                    items: original, incoming: [], children: children, expanded: [folder, nested], props: props,
                    filter: model.filter, choice: Settings.shared.sortingChoice, hideBackups: true,
                    sizes: [:], knownTags: [:], ordered: nil)
                let prepared = try #require(input.build())
                expectSameRows(prepared.rows, model.rows)
                #expect(prepared.groups.map(\.title) == model.groups.map(\.title))
                #expect(prepared.groups.map(\.firstRow) == model.groups.map(\.firstRow))
                #expect(prepared.groups.map(\.count) == model.groups.map(\.count))
                #expect(prepared.rows.contains { $0.item.url == leaf } == (mode == .details))
                #expect(prepared.rows.contains { $0.item.name == "keep-backup~" } == showHidden)
                if role != nil {
                    for (index, group) in prepared.groups.enumerated() {
                        #expect(group.count > 0)
                        #expect(prepared.rows[group.firstRow..<group.firstRow + group.count].allSatisfy { $0.group == index })
                    }
                } else {
                    #expect(prepared.groups.isEmpty && prepared.rows.allSatisfy { $0.group == -1 })
                }
            }
        }
    }

    @Test func incomingReplacementAndEqualSortTiesKeepTheSameRowOrder() throws {
        let s = try Scratch("row-ties")
        let model = DirectoryModel(location: s.url)
        var props = ViewProperties()
        props.mode = .details
        props.sortRole = .size
        props.groupRole = .size
        props.groupSameAsSort = false
        model.props = props
        let original = FileItem(url: s.path("original"), name: "before", isDirectory: false, size: 1)
        let twin1 = FileItem(url: s.path("twin1"), name: "same", isDirectory: false, size: 7)
        let twin2 = FileItem(url: s.path("twin2"), name: "same", isDirectory: false, size: 7)
        let replacement = FileItem(url: original.url, name: "after", isDirectory: false, size: 7)
        let added = FileItem(url: s.path("added"), name: "last", isDirectory: false, size: 9)
        model.applyEdit(ListingEdit(folder: s.url, added: [original, twin1, twin2]))
        model.applyEdit(ListingEdit(folder: s.url, replaced: [replacement], added: [added]))
        let input = DirectoryModelPreparation(
            items: [original, twin1, twin2], incoming: [replacement, added], children: [:], expanded: [],
            props: props, filter: NameFilter(), choice: Settings.shared.sortingChoice, hideBackups: false,
            sizes: [:], knownTags: [:], ordered: nil)
        let prepared = try #require(input.build())
        expectSameRows(prepared.rows, model.rows)
        #expect(prepared.rows.filter { $0.item.name == "same" }.map(\.item.url) == [twin1.url, twin2.url])
        #expect(prepared.rows.filter { $0.item.url == original.url }.map(\.item) == [replacement])
        #expect(prepared.groups.map(\.title) == model.groups.map(\.title))
        #expect(prepared.groups.map(\.count) == model.groups.map(\.count))
    }

    private func expectSameRows(_ actual: [Row], _ expected: [Row]) {
        #expect(actual.map(\.item) == expected.map(\.item))
        #expect(actual.map(\.depth) == expected.map(\.depth))
        #expect(actual.map(\.isExpanded) == expected.map(\.isExpanded))
        #expect(actual.map(\.group) == expected.map(\.group))
    }
}
