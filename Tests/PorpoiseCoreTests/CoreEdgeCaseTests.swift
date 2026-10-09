import Foundation
import Testing
@testable import PorpoiseCore

private func item(_ name: String, dir: Bool = false, size: Int64 = 0, type: String? = nil, mod: Date? = nil) -> FileItem {
    FileItem(url: URL(fileURLWithPath: "/tmp/x/" + name), name: name, isDirectory: dir, isHidden: name.hasPrefix("."),
             size: size, modificationDate: mod, contentType: type)
}

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

@Suite struct SortingEdgeCaseTests {
    private func names(_ items: [FileItem], _ props: ViewProperties = ViewProperties(), _ choice: SortingChoice = .natural) -> [String] {
        ItemSorter.sort(items, props: props, choice: choice).map(\.name)
    }

    @Test func naturalOrderOfNumbersAndCase() {
        let input = ["a10", "a2", "a1", "A3", "a02b", "b", "B1"].map { item($0) }
        #expect(names(input) == ["a1", "a2", "a02b", "A3", "a10", "b", "B1"])
    }

    @Test func choicesDiffer() {
        let input = ["b", "a10", "a9", "B"].map { item($0) }
        #expect(names(input, ViewProperties(), .caseSensitive) == ["B", "a10", "a9", "b"])
        #expect(names(input, ViewProperties(), .caseInsensitive).prefix(2) == ["a10", "a9"])
        #expect(names(input, ViewProperties(), .natural).prefix(2) == ["a9", "a10"])
    }

    @Test func unicodeNamesSortWithTheirLetters() {
        let input = ["Zebra", "éclair", "apple", "Ølen"].map { item($0) }
        let sorted = names(input)
        #expect(sorted.firstIndex(of: "éclair")! < sorted.firstIndex(of: "Zebra")!)
        #expect(sorted.first == "apple")
    }

    @Test func foldersMixWhenFoldersFirstIsOff() {
        var p = ViewProperties(); p.foldersFirst = false
        #expect(names([item("b"), item("a", dir: true), item("c", dir: true)], p) == ["a", "b", "c"])
    }

    @Test func ties() {
        // Same size: the name decides, in the sort direction.
        var p = ViewProperties(); p.sortRole = .size
        #expect(names([item("b", size: 1), item("a", size: 1)], p) == ["a", "b"])
        p.sortOrder = .descending
        #expect(names([item("a", size: 1), item("b", size: 1)], p) == ["b", "a"])
    }

    @Test func folderSizesUseChildCounts() {
        var p = ViewProperties(); p.sortRole = .size
        let a = item("a", dir: true), b = item("b", dir: true)
        let sorted = ItemSorter.sort([a, b], props: p, folderSizes: [a.url: 5, b.url: 1])
        #expect(sorted.map(\.name) == ["b", "a"])
    }

    @Test func missingDatesSortFirst() {
        var p = ViewProperties(); p.sortRole = .modificationTime
        #expect(names([item("dated", mod: Date()), item("undated")], p) == ["undated", "dated"])
    }

    @Test func extensionRoleAndGroups() {
        var p = ViewProperties(); p.sortRole = .extension_
        #expect(names([item("a.zip"), item("b.doc"), item("c")], p) == ["c", "b.doc", "a.zip"])
        #expect(ItemGrouper.groupName(item("x.PDF"), role: .extension_) == "pdf")
        #expect(ItemGrouper.groupName(item("noext"), role: .extension_) == "No extension")
    }

    @Test func sizeGroups() {
        #expect(ItemGrouper.groupName(item("s", size: 5 * 1024 * 1024 - 1), role: .size) == "Small")
        #expect(ItemGrouper.groupName(item("m", size: 5 * 1024 * 1024), role: .size) == "Medium")
        #expect(ItemGrouper.groupName(item("b", size: 10 * 1024 * 1024), role: .size) == "Big")
        #expect(ItemGrouper.groupName(item("d", dir: true), role: .size) == "Folders")
    }

    @Test func nameGroupsForUnicodeAndEmpty() {
        #expect(ItemGrouper.groupName(item("éclair"), role: .name) == "É")
        #expect(ItemGrouper.groupName(item(""), role: .name) == "")
        #expect(ItemGrouper.groupName(item(".hidden"), role: .name) == "Others")
    }

    @Test func dateGroups() {
        let cal = utc
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))!
        func group(daysAgo: Int) -> String {
            ItemGrouper.dateGroup(now.addingTimeInterval(TimeInterval(-daysAgo * 86400)), now: now, calendar: cal)
        }
        #expect(group(daysAgo: -3) == "Today")          // future dates
        #expect(group(daysAgo: 1) == "Yesterday")
        #expect(group(daysAgo: 2) == "Tuesday")
        #expect(group(daysAgo: 8) == "One Week Ago")
        #expect(group(daysAgo: 15) == "Two Weeks Ago")
        #expect(group(daysAgo: 22) == "Three Weeks Ago")
        #expect(group(daysAgo: 60) == "August")
        #expect(group(daysAgo: 400) == "September 2025")
    }
}

@Suite struct FilterEdgeCaseTests {
    private func matches(_ text: String, _ mode: FilterMode, _ names: [String], cs: Bool = false) throws -> [String] {
        let m = try #require(NameFilter(text: text, mode: mode, caseSensitive: cs).matcher())
        return names.filter(m)
    }

    @Test func globCharacterClasses() throws {
        let names = ["a1.txt", "b1.txt", "c1.txt", "ab.txt"]
        #expect(try matches("[ab]1.txt", .glob, names) == ["a1.txt", "b1.txt"])
        #expect(try matches("[!ab]1.txt", .glob, names) == ["c1.txt"])
        #expect(try matches("[a-b]?.txt", .glob, names) == ["a1.txt", "b1.txt", "ab.txt"])
    }

    @Test func globTreatsRegexCharactersLiterally() throws {
        #expect(try matches("a.b", .glob, ["a.b", "axb"]) == ["a.b"])
        #expect(try matches("(1)+*", .glob, ["(1)+x", "11"]) == ["(1)+x"])
        #expect(try matches("*", .glob, ["line\nbreak"]) == ["line\nbreak"])
    }

    @Test func globCaseSensitivity() throws {
        #expect(try matches("*.JPG", .glob, ["a.jpg", "b.JPG"]) == ["a.jpg", "b.JPG"])
        #expect(try matches("*.JPG", .glob, ["a.jpg", "b.JPG"], cs: true) == ["b.JPG"])
    }

    @Test func plainTextAndUnicode() throws {
        #expect(try matches("ÉT", .plainText, ["été", "ete"]) == ["été"])
        #expect(try matches("", .plainText, ["x"]) == ["x"])   // inactive filter shows everything
    }

    @Test func invalidPatterns() {
        #expect(NameFilter(text: "[abc", mode: .glob).matcher() == nil)
        #expect(NameFilter(text: "a{2,1}", mode: .regex).matcher() == nil)
    }
}

@Suite struct FormatEdgeCaseTests {
    @Test func sizeBoundaries() {
        #expect(FileFormat.size(1023) == "1023 B")
        #expect(FileFormat.size(1024) == "1.0 KiB")
        #expect(FileFormat.size(1024 * 1024 - 1) == "1.0 MiB")   // not "1024.0 KiB"
        #expect(FileFormat.size(Int64.max).hasSuffix("EiB"))
    }

    @Test func numberedNamesKeepDoubleExtensions() {
        #expect(FileFormat.duplicateName(for: "backup.tar.gz", existing: []) == "backup copy.tar.gz")
        #expect(FileFormat.suggestedName(for: "backup.tar.gz", existing: []) == "backup (1).tar.gz")
        #expect(FileFormat.suggestedName(for: "backup (4).tar.xz", existing: []) == "backup (5).tar.xz")
        #expect(FileFormat.duplicateName(for: ".bashrc", existing: []) == ".bashrc copy")
        #expect(FileFormat.suggestedName(for: "README", existing: ["README (1)"]) == "README (2)")
        #expect(FileFormat.duplicateName(for: "a.tar", existing: []) == "a copy.tar")
    }

    @Test func permissionsString() {
        #expect(FileFormat.permissions(0o640, isDirectory: false) == "-rw-r-----")
        #expect(FileFormat.permissions(0, isDirectory: true) == "d---------")
    }

    @Test func summaryWording() {
        #expect(FileFormat.summary(folders: 0, files: 3, bytes: 0, selected: true) == "3 files selected (0 B)")
        #expect(FileFormat.summary(folders: 0, files: 0, bytes: 0, selected: false) == "")
        #expect(FileFormat.itemCount(1) == "1 item" && FileFormat.itemCount(0) == "0 items")
    }

    @Test func relativeDates() {
        let cal = utc
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))!
        #expect(FileFormat.relativeDate(now, now: now, calendar: cal).hasPrefix("Today at "))
        #expect(FileFormat.relativeDate(now.addingTimeInterval(-86400), now: now, calendar: cal).hasPrefix("Yesterday at "))
        #expect(FileFormat.relativeDate(now.addingTimeInterval(-3 * 86400), now: now, calendar: cal).hasPrefix("Monday at "))
        let old = FileFormat.relativeDate(now.addingTimeInterval(-30 * 86400), now: now, calendar: cal)
        #expect(!old.hasPrefix("Today") && !old.hasPrefix("Yesterday") && !old.hasPrefix("Tuesday"))
    }
}

@Suite struct HistoryEdgeCaseTests {
    private func u(_ s: String) -> URL { URL(fileURLWithPath: "/" + s) }

    @Test func revisitingTheCurrentFolderIsIgnored() {
        var h = NavigationHistory(start: u("a"))
        h.visit(u("a"))
        #expect(h.entries.count == 1 && !h.canGoBack)
    }

    @Test func capsTheNumberOfEntries() {
        var h = NavigationHistory(start: u("0"))
        for i in 1...150 { h.visit(u(String(i))) }
        #expect(h.entries.count == NavigationHistory.maxEntries)
        #expect(h.current == u("150") && h.entries.first == u("51"))
    }

    @Test func multiStepAndInvalidSteps() {
        var h = NavigationHistory(start: u("a"))
        h.visit(u("b")); h.visit(u("c")); h.visit(u("d"))
        #expect(h.goBack(3) == u("a"))
        #expect(h.goBack() == nil)
        #expect(h.goForward(0) == nil && h.goBack(-1) == nil)   // never moves the other way
        #expect(h.goForward(2) == u("c"))
        #expect(h.forwardList == [u("d")] && h.backList == [u("b"), u("a")])
    }

    @Test func watcherReportsParentOfChangedItems() {
        let watched: Set<String> = ["/w", "/w/sub"]
        #expect(FolderWatcher.changedFolders(["/w/file"], watched: watched) == ["/w"])
        #expect(FolderWatcher.changedFolders(["/w/sub"], watched: watched) == ["/w/sub"])
        #expect(FolderWatcher.changedFolders(["/elsewhere/x"], watched: watched).isEmpty)
    }
}

@Suite struct ViewPropertiesEdgeCaseTests {
    @Test func iconSizeIsClamped() {
        var p = ViewProperties()
        p.setIconSize(9999, for: .icons)
        #expect(p.iconSize(for: .icons) == ZoomLevels.maxSize)
        p.setIconSize(1, for: .details)
        #expect(p.iconSize(for: .details) == ZoomLevels.minSize)
        p.resetIconSize(for: .details)
        #expect(p.iconSize(for: .details) == ZoomLevels.iconSize(for: ViewMode.details.defaultPreviewZoom))
    }

    @Test func rolesNeverIncludeName() {
        var p = ViewProperties()
        #expect(p.roles(for: .details) == [.size, .modificationTime])
        p.setRoles([.name, .type], for: .icons)
        #expect(p.roles(for: .icons) == [.type])
    }

    @Test func roundTripsThroughJSON() throws {
        var p = ViewProperties(); p.mode = .compact; p.groupRole = .type; p.setIconSize(40, for: .compact)
        let back = try JSONDecoder().decode(ViewProperties.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    @Test func zoomLevelEdges() {
        #expect(ZoomLevels.iconSize(for: -5) == 16 && ZoomLevels.iconSize(for: 99) == 256)
        #expect(ZoomLevels.step(from: 256, by: 1) == 256 && ZoomLevels.step(from: 16, by: -1) == 16)
        #expect(ZoomLevels.continuousLevel(for: 8) == 0 && ZoomLevels.continuousLevel(for: 999) == 16)
    }
}
