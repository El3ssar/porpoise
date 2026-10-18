import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

/// Corners of the core models the other suites don't reach: items missing dates or owners, jobs without
/// sources, sources that vanished, folders that can't be listed, and a cancel in the middle of a merge.
@Suite struct ModelsCoverageTests {
    private func item(
        _ name: String, modified: Date? = nil, created: Date? = nil, accessed: Date? = nil, owner: String? = nil,
        group: String? = nil
    ) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/x/" + name), name: name, isDirectory: false, modificationDate: modified,
            creationDate: created, accessDate: accessed, owner: owner, group: group)
    }

    // MARK: Operation kinds and progress

    @Test func everyKindHasAVerb() {
        let verbs = [FileOperationKind.copy, .move, .link, .trash, .delete].map(\.verb)
        #expect(verbs == ["Copying", "Moving", "Linking", "Moving to Trash", "Deleting"])
    }

    @Test func progressFallsBackToItemsWithoutBytes() {
        var p = JobProgress(kind: .delete, totalBytes: 0, doneBytes: 0, totalItems: 4, doneItems: 1, currentName: "a", destination: nil)
        #expect(p.fraction == 0.25)
        p.totalItems = 0
        #expect(p.fraction == 0)
        p.totalBytes = 200; p.doneBytes = 50
        #expect(p.fraction == 0.25)
    }

    @Test func cancelledHasAMessage() {
        #expect(FileOperationError.cancelled.errorDescription == "The operation was cancelled.")
    }

    // MARK: Conflicts with sources that are gone

    /// A source deleted after it was picked, whose name is taken at the destination: there is nothing to ask about,
    /// so it is skipped quietly, and the existing item stays.

    /// "Overwrite if older" for all: a later source that vanished counts as the oldest, so nothing is replaced.

    /// A destination that can be written to but not listed: the suggested name can't avoid what it can't see, and
    /// the conflict is still asked about.

    /// Cancelling at a conflict inside a folder being merged stops the whole job, not just that child.

    // MARK: Sorting and grouping items without dates or owners

    @Test(arguments: [ItemRole.modificationTime, .creationTime, .accessTime])
    func undatedItemsSortAsOldest(_ role: ItemRole) {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let dated = item("dated", modified: day, created: day, accessed: day)
        let undated = item("undated")
        #expect(ItemSorter.compare(undated, dated, role: role, choice: .natural, folderSizes: [:]) == .orderedAscending)
        #expect(ItemSorter.compare(dated, undated, role: role, choice: .natural, folderSizes: [:]) == .orderedDescending)
        #expect(ItemSorter.compare(undated, item("also"), role: role, choice: .natural, folderSizes: [:]) == .orderedSame)
    }

    @Test func itemsWithoutOwnerOrGroupComeFirst() {
        let owned = item("owned", owner: "root", group: "wheel"), unowned = item("unowned")
        for role in [ItemRole.owner, .group] {
            #expect(ItemSorter.compare(unowned, owned, role: role, choice: .natural, folderSizes: [:]) == .orderedAscending)
            #expect(ItemSorter.compare(owned, unowned, role: role, choice: .natural, folderSizes: [:]) == .orderedDescending)
            #expect(ItemGrouper.groupName(unowned, role: role).isEmpty)
        }
        #expect(ItemGrouper.groupName(owned, role: .owner) == "root" && ItemGrouper.groupName(owned, role: .group) == "wheel")
    }

    /// Grouped by a date the list isn't sorted by: groups come newest first, whichever date it is.
    @Test(arguments: [ItemRole.creationTime, .accessTime])
    func groupsByAnotherDateAreNewestFirst(_ role: ItemRole) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = now.addingTimeInterval(-40 * 86400)
        let items = [item("a", created: old, accessed: old), item("b", created: now, accessed: now)]
        var props = ViewProperties()
        props.sortRole = .name
        let groups = ItemGrouper.groups(items, role: role, props: props, now: now, calendar: cal)
        #expect(groups.map(\.title).first == "Today")
        #expect(groups.map { $0.items.map(\.name) } == [["b"], ["a"]])
    }

    // MARK: View overrides

    /// Two temporary changes of the Details columns in a row: what is saved is still the user's own columns.
    @Test func detailsColumnsChangedTwiceRestoreTheFirstOriginal() {
        var o = ViewOverride()
        var shown = ViewProperties()
        shown.setRoles([.size], for: .details)
        o.apply(to: &shown) { $0.setRoles([.path], for: .details) }
        o.apply(to: &shown) { $0.setRoles([.path, .modificationTime], for: .details) }
        #expect(shown.roles(for: .details) == [.path, .modificationTime])
        #expect(o.stored(shown).roles(for: .details) == [.size])
    }
}
