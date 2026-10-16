import Foundation
import Testing

@testable import PorpoiseCore

/// The Shared column (cloud items shared with the user).
@Suite struct SharedDateTests {
    @Test func sortsAndGroupsBySharedDate() {
        let now = Date()
        let old = FileItem(url: URL(string: "gdrive://a/x/1/")!, name: "old", isDirectory: false, sharedDate: now.addingTimeInterval(-86400 * 40))
        let new = FileItem(url: URL(string: "gdrive://a/x/2/")!, name: "new", isDirectory: false, sharedDate: now)
        let none = FileItem(url: URL(string: "gdrive://a/x/3/")!, name: "none", isDirectory: false)
        #expect(ItemSorter.compare(old, new, role: .sharedTime, choice: .natural, folderSizes: [:]) == .orderedAscending)
        #expect(ItemSorter.compare(none, old, role: .sharedTime, choice: .natural, folderSizes: [:]) == .orderedAscending)
        #expect(ItemGrouper.groupName(none, role: .sharedTime, now: now) == "Unknown")
        var props = ViewProperties()
        props.sortRole = .name
        props.foldersFirst = false
        // Grouped by another role: newest groups first, as for the other dates.
        let groups = ItemGrouper.groups([old, new], role: .sharedTime, props: props, now: now)
        #expect(groups.first?.items.first?.name == "new")
    }

    @Test func overridesRestoreTheUsersSorting() {
        var props = ViewProperties()
        var o = ViewOverride()
        o.apply(to: &props) { p in
            p.sortRole = .sharedTime
            p.sortOrder = .descending
            p.foldersFirst = false
        }
        #expect(!o.isEmpty && props.sortRole == .sharedTime)
        let stored = o.stored(props)
        #expect(stored.sortRole == .name && stored.sortOrder == .ascending && stored.foldersFirst)
        // Changed by the user meanwhile: theirs to keep.
        props.sortRole = .size
        #expect(o.stored(props).sortRole == .size)
    }
}
