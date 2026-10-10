import Foundation
import Testing
@testable import PorpoiseCore
import PorpoiseTestSupport

/// FileItem.load on every kind of item a folder can hold.
@Suite struct FileItemLoadingTests {
    let fm = FileManager.default

    private func load(_ url: URL) throws -> FileItem { try #require(FileItem.load(url)) }

    @Test func plainFile() throws {
        let s = try Scratch()
        let url = try s.file("notes.txt", "hello")
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let it = try load(url)
        #expect(it.name == "notes.txt" && !it.isDirectory && !it.isSymlink && !it.isHidden && !it.isPackage)
        #expect(it.size == 5 && it.fileExtension == "txt")
        #expect(it.contentType == "public.plain-text" && it.mimeType == "text/plain")
        #expect(it.posixPermissions == 0o640 && it.owner == NSUserName() && it.group != nil)
        #expect(it.isReadable && it.isWritable && it.linkDestination == nil)
        #expect(it.modificationDate != nil && it.creationDate != nil)
        #expect(!it.typeDescription.isEmpty && it.typeDescription.first!.isUppercase)
    }

    @Test func folder() throws {
        let s = try Scratch()
        let it = try load(s.folder("Stuff.d"))
        #expect(it.isDirectory && it.isBrowsableFolder && !it.isPackage)
        #expect(it.fileExtension == "" && it.typeDescription == "Folder" && it.mimeType == "inode/directory")
    }

    @Test func packagesAndApps() throws {
        let s = try Scratch()
        try s.file("Mini.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleIdentifier</key><string>app.porpoise.tests.mini</string></dict></plist>
        """)
        let app = try load(s.path("Mini.app"))
        #expect(app.isDirectory && app.isPackage && app.isApplication && !app.isBrowsableFolder)
        #expect(app.fileExtension == "app")
        let bundle = try load(s.folder("Thing.bundle"))
        #expect(bundle.isPackage && !bundle.isApplication && !bundle.isBrowsableFolder)
    }

    @Test func symlinksReportTheirTarget() throws {
        let s = try Scratch()
        try s.file("target.txt", "12345678")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: s.folder("dir").path)
        let toFile = try load(s.symlink("file-link", to: "target.txt"))
        #expect(toFile.isSymlink && !toFile.isDirectory && toFile.size == 8)
        #expect(toFile.linkDestination == "target.txt" && toFile.contentType == "public.plain-text")
        let toFolder = try load(s.symlink("dir-link", to: s.path("dir").path))
        #expect(toFolder.isSymlink && toFolder.isBrowsableFolder)
        #expect(toFolder.linkDestination == s.path("dir").path)
        // The link's own permissions, not its target's.
        #expect(toFolder.posixPermissions == 0o755)
    }

    @Test func danglingLink() throws {
        let s = try Scratch()
        let it = try load(s.symlink("broken", to: "nowhere"))
        #expect(it.isSymlink && !it.isDirectory && it.linkDestination == "nowhere")
    }

    @Test func aliasFile() throws {
        let s = try Scratch()
        let target = try s.folder("Real")
        let alias = s.path("Real alias")
        let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: alias)
        let it = try load(alias)
        #expect(it.isAliasFile && !it.isDirectory && !it.isSymlink)
    }

    @Test func hiddenItems() throws {
        let s = try Scratch()
        #expect(try load(s.file(".profile")).isHidden)
        let flagged = try s.file("flagged")
        var values = URLResourceValues()
        values.isHidden = true
        var u = flagged
        try u.setResourceValues(values)
        #expect(try load(flagged).isHidden)
        #expect(try !load(s.file("plain")).isHidden)
    }

    @Test func unreadableAndReadOnlyItems() throws {
        let s = try Scratch()
        let locked = try s.file("locked", "x")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        let it = try load(locked)
        #expect(!it.isReadable && !it.isWritable && it.posixPermissions == 0)
        let readOnly = try s.file("ro", "x")
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        #expect(try load(readOnly).isReadable && !load(readOnly).isWritable)
        #expect(FileItem.load(s.path("missing")) == nil)
    }

    @Test func ownerNamesAreLookedUpOnce() {
        #expect(FileItem.userName(0) == "root")
        #expect(FileItem.userName(0) == "root")
        #expect(FileItem.groupName(0) == "wheel")
        // Unknown ids show as numbers.
        #expect(FileItem.userName(54321) == "54321")
        #expect(FileItem.groupName(54321) == "54321")
    }

    @Test func typeDescriptionsWithoutAType() {
        func item(_ name: String) -> FileItem { FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, isDirectory: false) }
        #expect(item("README").typeDescription == "File")
        #expect(item("data.qqq").typeDescription == "QQQ file")
        #expect(item("README").mimeType == nil)
    }

    @Test func listingAFolder() throws {
        let s = try Scratch()
        try s.file("a"); try s.file(".b"); try s.folder("c")
        let names = try DirectoryLister.list(s.url).map(\.name).sorted()
        #expect(names == [".b", "a", "c"])
        #expect(DirectoryLister.childCount(s.url, includeHidden: false) == 2)
        #expect(DirectoryLister.childCount(s.url, includeHidden: true) == 3)
        #expect(DirectoryLister.childCount(s.path("missing"), includeHidden: true) == nil)
        #expect(throws: (any Error).self) { try DirectoryLister.list(s.path("missing")) }
    }
}

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
        #expect(Set(json?.keys.map { $0 } ?? []) == ["mode", "sortRole", "sortOrder", "foldersFirst", "hiddenLast", "groupRole",
                                                    "groupSameAsSort", "showHidden", "previews", "extraRoles", "zoom", "sizes"])
        #expect((json?["sizes"] as? [String: Double])?["icons.preview"] == 40)
    }

    @Test func legacyZoomLevels() throws {
        let p = try JSONDecoder().decode(ViewProperties.self, from: Data(#"{"zoom":{"icons.preview":6,"details":1}}"#.utf8))
        #expect(p.iconSize(for: .icons) == 96)
        #expect(p.zoomLevel(for: .icons) == 6)
        var q = p
        q.previews = false
        #expect(q.iconSize(for: .details) == 22)
        #expect(q.iconSize(for: .compact) == 16)   // nothing saved: the mode's default
        // A new size replaces the legacy level.
        q.setZoomLevel(3, for: .details)
        #expect(q.iconSize(for: .details) == 48 && q.zoom["details"] == nil)
    }

    @Test func defaultsDependOnPreviews() {
        var p = ViewProperties()
        #expect(p.iconSize(for: .icons) == 64 && p.iconSize(for: .details) == 32)
        p.previews = false
        #expect(p.iconSize(for: .icons) == 32 && p.iconSize(for: .details) == 16)
    }

    @Test func specialFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let trash = ViewProperties.defaults(for: home.appendingPathComponent(".Trash"))
        #expect(trash.mode == .details && trash.roles(for: .details) == [.path, .modificationTime])
        let downloads = ViewProperties.defaults(for: home.appendingPathComponent("Downloads"))
        #expect(downloads.sortRole == .modificationTime && downloads.sortOrder == .descending && !downloads.foldersFirst)
        #expect(ViewProperties.defaults(for: home.appendingPathComponent("Documents")) == ViewProperties())
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
        #expect(ViewMode.allCases.map(\.title) == ["Icons", "Compact", "Details"])
        #expect(Set(ViewMode.allCases.map(\.iconName)).count == 3)
        #expect(ViewMode.allCases.map(\.defaultZoom) == [2, 0, 0])
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
    private func item(_ name: String, created: Date? = nil, accessed: Date? = nil, perms: Int = 0o644, owner: String? = nil,
                      group: String? = nil, link: String? = nil, type: String? = nil, folder: String = "/x") -> FileItem {
        FileItem(url: URL(fileURLWithPath: folder + "/" + name), name: name, isDirectory: false, creationDate: created,
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
