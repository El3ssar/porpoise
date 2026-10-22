import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

@Suite struct ViewPropertiesTests {
    @Test func olderSettingsDecodeWithDefaults() throws {
        let old = try JSONDecoder().decode(ViewProperties.self, from: Data(#"{"mode":"details","showHidden":true}"#.utf8))
        var expected = ViewProperties()
        expected.mode = .details
        expected.showHidden = true
        #expect(old == expected)
        #expect(try JSONDecoder().decode(ViewProperties.self, from: Data("{}".utf8)) == ViewProperties())
        // A value a later version wrote isn't silently replaced.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ViewProperties.self, from: Data(#"{"mode":"gallery"}"#.utf8))
        }
    }

    @Test func storedKeysStayTheSame() throws {
        var p = ViewProperties()
        p.groupRole = .type
        p.setIconSize(40, for: .icons)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any]
        #expect(
            Set(json?.keys.map { $0 } ?? []) == [
                "mode", "sortRole", "sortOrder", "foldersFirst", "hiddenLast", "groupRole",
                "groupSameAsSort", "showHidden", "previews", "extraRoles", "zoom", "sizes",
            ])
        #expect((json?["sizes"] as? [String: Double])?["icons.preview"] == 40)
    }

    @Test func legacyZoomLevels() throws {
        let p = try JSONDecoder().decode(ViewProperties.self, from: Data(#"{"zoom":{"icons.preview":6,"details":1}}"#.utf8))
        #expect(p.iconSize(for: .icons) == 96)
        #expect(p.zoomLevel(for: .icons) == 6)
        var q = p
        q.previews = false
        #expect(q.iconSize(for: .details) == 22)
        #expect(q.iconSize(for: .compact) == 16)  // nothing saved: the mode's default
        // A new size replaces the legacy level.
        q.setIconSize(ZoomLevels.iconSize(for: 3), for: .details)
        #expect(q.iconSize(for: .details) == 48 && q.zoom["details"] == nil)
    }

    @Test func defaultsDependOnPreviews() {
        var p = ViewProperties()
        #expect(p.iconSize(for: .icons) == 64 && p.iconSize(for: .details) == 32)
        p.previews = false
        #expect(p.iconSize(for: .icons) == 32 && p.iconSize(for: .details) == 16)
    }

    @Test func specialFolders() {
        let home = URL(fileURLWithPath: "/fixture/home")
        let trash = ViewProperties.defaults(for: home.appendingPathComponent(".Trash"), home: home)
        #expect(trash.mode == .details && trash.roles(for: .details) == [.path, .modificationTime])
        let downloads = ViewProperties.defaults(for: home.appendingPathComponent("Downloads"), home: home)
        #expect(downloads.sortRole == .modificationTime && downloads.sortOrder == .descending && !downloads.foldersFirst)
        #expect(ViewProperties.defaults(for: home.appendingPathComponent("Documents"), home: home) == ViewProperties())
    }

    @Test func groupingFollowsTheSortWhenAsked() {
        var p = ViewProperties()
        p.groupRole = .type
        #expect(p.effectiveGroupRole == .type)
        p.groupSameAsSort = true
        p.sortRole = .size
        #expect(p.effectiveGroupRole == .size)
    }

    @Test func labelsForMenusAndColumns() {
        #expect(ViewMode.allCases.map(\.title) == ["Icons", "Compact", "Details", "Columns"])
        #expect(Set(ViewMode.allCases.map(\.iconName)).count == 4)
        #expect(ViewMode.allCases.map(\.defaultZoom) == [2, 0, 0, 0])
        // Column view keeps Finder's 16 pt rows with previews on too.
        #expect(ViewMode.allCases.map(\.defaultPreviewZoom) == [4, 2, 2, 0])
        #expect(Set(ItemRole.allCases.map(\.title)).count == ItemRole.allCases.count)
        #expect(Set(ItemRole.menuRoles + ItemRole.otherRoles) == Set(ItemRole.allCases))
        #expect(ItemRole.name.orderLabels.ascending == "A-Z" && ItemRole.size.orderLabels.descending == "Largest First")
        #expect(ItemRole.creationTime.orderLabels.descending == "Newest First" && ItemRole.owner.orderLabels.ascending == "Ascending")
        #expect(ItemRole.allCases.allSatisfy { $0.defaultColumnWidth >= 90 })
        #expect(ItemRole.allCases.filter(\.rightAligned) == [.size])
        #expect(FilterMode.allCases.map(\.title) == ["Plain Text", "Glob Pattern", "Regular Expression"])
        #expect(SortingChoice.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

@Suite struct SortingByEveryRoleTests {
    private func item(
        _ name: String, created: Date? = nil, accessed: Date? = nil, perms: Int = 0o644, owner: String? = nil,
        group: String? = nil, link: String? = nil, type: String? = nil, folder: String = "/x"
    ) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: folder + "/" + name), name: name, isDirectory: false, creationDate: created,
            accessDate: accessed, contentType: type, posixPermissions: perms, owner: owner, group: group, linkDestination: link)
    }

    private func sorted(_ items: [FileItem], by role: ItemRole, _ order: PorpoiseCore.SortOrder = .ascending) -> [String] {
        var p = ViewProperties()
        p.sortRole = role
        p.sortOrder = order
        return ItemSorter.sort(items, props: p).map(\.name)
    }

    @Test func eachRoleOrdersByItsValue() {
        let d = Date()
        #expect(sorted([item("a", created: d), item("b", created: d - 10)], by: .creationTime) == ["b", "a"])
        #expect(sorted([item("a", accessed: d), item("b")], by: .accessTime) == ["b", "a"])
        #expect(sorted([item("a", perms: 0o755), item("b", perms: 0o600)], by: .permissions) == ["b", "a"])
        #expect(sorted([item("a", owner: "zed"), item("b", owner: "amy"), item("c")], by: .owner) == ["c", "b", "a"])
        #expect(sorted([item("a", group: "wheel"), item("b", group: "staff")], by: .group) == ["b", "a"])
        #expect(sorted([item("a", link: "/z"), item("b", link: "/a"), item("c")], by: .linkDestination) == ["c", "b", "a"])
        #expect(sorted([item("a", folder: "/x/y"), item("b", folder: "/x")], by: .path) == ["b", "a"])
        #expect(sorted([item("a.txt", type: "public.plain-text"), item("b.jpg", type: "public.jpeg")], by: .type).count == 2)
        #expect(sorted([item("a", perms: 0o755), item("b", perms: 0o600)], by: .permissions, .descending) == ["a", "b"])
    }

    /// Same name in two folders (search results): the path decides, so the order is stable.
    @Test func sameNameTieBreaksOnPath() {
        let a = item("same", folder: "/b"), b = item("same", folder: "/a")
        #expect(ItemSorter.sort([a, b], props: ViewProperties()).map(\.url.path) == ["/a/same", "/b/same"])
    }

    @Test func groupNamesForOtherRoles() {
        let it = item("x", perms: 0o750, owner: "amy", group: "staff", link: "/t", folder: "/p/q")
        #expect(ItemGrouper.groupName(it, role: .owner) == "amy")
        #expect(ItemGrouper.groupName(it, role: .group) == "staff")
        #expect(ItemGrouper.groupName(it, role: .permissions) == "-rwxr-x---")
        #expect(ItemGrouper.groupName(it, role: .path) == "/p/q")
        #expect(ItemGrouper.groupName(it, role: .linkDestination) == "/t")
        #expect(ItemGrouper.groupName(it, role: .creationTime) == "Unknown")
        #expect(ItemGrouper.groupName(item("y"), role: .tags) == "No Tags")
        #expect(ItemGrouper.groupName(item("y"), role: .tags, tags: ["Red", "Blue"]) == "Red")
        #expect(ItemGrouper.groupName(item("y"), role: .type) == "File")
    }
}
