import Foundation
import Testing

@testable import PorpoiseCore

@Suite struct CancellableSortingTests {
    private func items(_ count: Int = 600) -> [FileItem] {
        (0..<count).map { index in
            let number = index * 173 % count
            let name = ["é", "File", "file", ".hidden"][index % 4] + "\(number).txt"
            return FileItem(
                url: URL(fileURLWithPath: "/tmp/cancellable-sort/\(index)/\(name)"), name: name,
                isDirectory: index % 5 == 0, isHidden: index % 4 == 3, size: Int64(index % 13),
                modificationDate: Date(timeIntervalSince1970: Double(index % 7)))
        }
    }

    @Test(arguments: SortingChoice.allCases)
    func successfulSortAndMergeKeepTheExistingOrder(choice: SortingChoice) throws {
        let all = items()
        let tags = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.url, $0.offset % 3 == 0 ? ["Red"] : []) })
        for role in ItemRole.allCases {
            for order in [SortOrder.ascending, .descending] {
                for foldersFirst in [false, true] {
                    var props = ViewProperties()
                    props.sortRole = role
                    props.sortOrder = order
                    props.foldersFirst = foldersFirst
                    props.hiddenLast = true
                    let expected = ItemSorter.sort(all, props: props, choice: choice, tags: tags)
                    let actual = try #require(ItemSorter.sort(all, props: props, choice: choice, tags: tags, cancelled: { false }))
                    #expect(actual == expected)
                    // The merge API has no tag payload; compare its full-sort oracle with the same inputs.
                    let first = ItemSorter.sort(Array(all.prefix(300)), props: props, choice: choice)
                    let merged = try #require(
                        ItemSorter.merge(first, adding: Array(all.dropFirst(300)), props: props, choice: choice, cancelled: { false }))
                    #expect(merged == ItemSorter.sort(all, props: props, choice: choice))
                }
            }
        }
    }

    @Test func cancelledSortNeverReturnsPartialRows() {
        let all = items(10_000)
        var checks = 0
        let result = ItemSorter.sort(all, props: ViewProperties(), cancelled: {
            checks += 1
            return checks >= 4
        })
        #expect(result == nil)
        // A request can be cancelled after comparisons have begun, without finishing the whole sort.
        #expect(checks == 5)
        #expect(all.count == 10_000 && all[1].name == "File173.txt")
    }

    @Test func cancellationIsCheckedBeforeStartingAndAfterTinySorts() {
        var checks = 0
        #expect(ItemSorter.sort(items(), props: ViewProperties(), cancelled: { checks += 1; return true }) == nil)
        #expect(checks == 1)
        for input in [[], Array(items().prefix(1))] {
            checks = 0
            #expect(ItemSorter.sort(input, props: ViewProperties(), cancelled: { checks += 1; return checks == 2 }) == nil)
            #expect(checks == 2)
        }
    }

    @Test func mergingCanStopAfterSortingNewResults() {
        let all = items(10_000)
        let first = ItemSorter.sort(Array(all.prefix(5000)), props: ViewProperties())
        let more = Array(all.dropFirst(5000))
        var sortingChecks = 0
        _ = ItemSorter.sort(more, props: ViewProperties(), cancelled: { sortingChecks += 1; return false })
        var checks = 0
        #expect(
            ItemSorter.merge(first, adding: more, props: ViewProperties(), cancelled: {
                checks += 1
                return checks == sortingChecks + 2
            }) == nil)
        #expect(checks == sortingChecks + 2)
        #expect(ItemSorter.merge(first, adding: [], props: ViewProperties(), cancelled: { true }) == nil)
    }
}
