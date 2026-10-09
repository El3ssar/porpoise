import Foundation
import Testing
@testable import PorpoiseCore

private func item(_ name: String, dir: Bool = false, size: Int64 = 0, mod: Date? = nil) -> FileItem {
    FileItem(url: URL(fileURLWithPath: "/tmp/x/" + name), name: name, isDirectory: dir, isHidden: name.hasPrefix("."),
             size: size, modificationDate: mod)
}

@Suite struct ViewOverrideTests {
    private func detailsStyle() -> ViewProperties {
        var p = ViewProperties()
        p.mode = .details
        p.previews = false
        return p
    }

    @Test func temporaryChangeIsNeverSaved() {
        var o = ViewOverride()
        var shown = detailsStyle()
        o.apply(to: &shown) { $0.mode = .icons; $0.previews = true }
        #expect(shown.mode == .icons && shown.previews)
        // The user changes something else (sorting): that is saved, the media-folder Icons view is not.
        shown.sortRole = .size
        let saved = o.stored(shown)
        #expect(saved.mode == .details)
        #expect(!saved.previews)
        #expect(saved.sortRole == .size)
    }

    @Test func fieldTheUserChangesIsTheirs() {
        var o = ViewOverride()
        var shown = detailsStyle()
        o.apply(to: &shown) { $0.mode = .icons; $0.previews = true }
        shown.mode = .compact
        #expect(o.stored(shown).mode == .compact)
        // ...and stays theirs, even when they go back to the temporary value later.
        shown.mode = .icons
        #expect(o.stored(shown).mode == .icons)
        // Previews were not touched: still the user's own value.
        #expect(!o.stored(shown).previews)
    }

    @Test func nestedOverridesKeepFirstOriginal() {
        // Media folder (Icons) and then a search (Details + Path): saving restores the folder's own Compact style.
        var dynamic = ViewOverride(), search = ViewOverride()
        var shown = ViewProperties()
        shown.mode = .compact
        dynamic.apply(to: &shown) { $0.mode = .icons }
        search.apply(to: &shown) { $0.mode = .details; $0.setRoles([.path, .modificationTime], for: .details) }
        search.apply(to: &shown) { $0.mode = .details }   // every new search text applies it again
        let saved = dynamic.stored(search.stored(shown))
        #expect(saved.mode == .compact)
        #expect(saved.extraRoles["details"] == nil)
        #expect(saved.roles(for: .details) == [.size, .modificationTime])
        // Closing the search shows the media-folder Icons view again.
        #expect(search.removed(from: shown).mode == .icons)
        #expect(search.isEmpty)
    }

    @Test func untouchedFieldsAreNotOverridden() {
        var o = ViewOverride()
        var shown = ViewProperties()   // already Icons with previews
        o.apply(to: &shown) { $0.mode = .icons; $0.previews = true }
        #expect(o.isEmpty)
    }
}

@Suite struct TagSortingAndGroupingTests {
    @Test func sortByTagsPutsTaggedFirst() {
        var p = ViewProperties()
        p.sortRole = .tags
        let a = item("a"), b = item("b"), c = item("c")
        let tags = [b.url: ["Red"], c.url: ["Blue"]]
        #expect(ItemSorter.sort([a, b, c], props: p, tags: tags).map(\.name) == ["c", "b", "a"])
    }

    @Test func groupByTags() {
        #expect(ItemGrouper.groupName(item("a"), role: .tags) == "No Tags")
        #expect(ItemGrouper.groupName(item("a"), role: .tags, tags: ["Work", "Red"]) == "Work")
    }
}

@Suite struct GroupingTests {
    @Test func foldersFirstKeepsFoldersInTheirOwnGroups() {
        var p = ViewProperties()
        p.groupSameAsSort = true
        let sorted = ItemSorter.sort([item("apple.txt"), item("Apps", dir: true), item("banana.txt"), item("Books", dir: true)], props: p)
        let g = ItemGrouper.groups(sorted, role: .name, props: p)
        #expect(g.map(\.title) == ["A", "B", "A", "B"])
        #expect(g.map { $0.items.map(\.name) } == [["Apps"], ["Books"], ["apple.txt"], ["banana.txt"]])
    }

    @Test func otherRoleGroupsAreOrderedByThatRole() {
        let now = Date()
        var p = ViewProperties()
        p.foldersFirst = false
        p.groupRole = .modificationTime
        let old = now.addingTimeInterval(-86_400 * 400)
        let items = [item("a", mod: old), item("b", mod: now), item("c", mod: old), item("d", mod: now)]
        let g = ItemGrouper.groups(ItemSorter.sort(items, props: p), role: .modificationTime, props: p, now: now)
        // Sorted by name, grouped by date: one group per date, newest first, names in order inside.
        #expect(g.count == 2)
        #expect(g[0].title == "Today")
        #expect(g[0].items.map(\.name) == ["b", "d"])
        #expect(g[1].items.map(\.name) == ["a", "c"])
    }

    @Test func sameAsSortFollowsSortOrder() {
        var p = ViewProperties()
        p.foldersFirst = false
        p.sortRole = .size
        p.sortOrder = .descending
        p.groupSameAsSort = true
        let items = [item("s", size: 10), item("b", size: 20 * 1024 * 1024)]
        let g = ItemGrouper.groups(ItemSorter.sort(items, props: p), role: .size, props: p)
        #expect(g.map(\.title) == ["Big", "Small"])
    }
}
