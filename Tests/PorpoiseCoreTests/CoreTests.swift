import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseCore

private func item(_ name: String, dir: Bool = false, size: Int64 = 0, hidden: Bool = false, mod: Date? = nil) -> FileItem {
    FileItem(
        url: URL(fileURLWithPath: "/tmp/x/" + name), name: name, isDirectory: dir,
        isHidden: hidden || name.hasPrefix("."), size: size, modificationDate: mod)
}

@Suite struct SortingTests {
    @Test func naturalSortWithFoldersFirst() {
        let items = [item("file10.txt"), item("file2.txt"), item("Zeta", dir: true), item("alpha", dir: true), item("File1.txt")]
        let sorted = ItemSorter.sort(items, props: ViewProperties())
        #expect(sorted.map(\.name) == ["alpha", "Zeta", "File1.txt", "file2.txt", "file10.txt"])
    }

    @Test func descendingKeepsFoldersFirst() {
        var p = ViewProperties(); p.sortOrder = .descending
        let sorted = ItemSorter.sort([item("a"), item("b"), item("dir", dir: true)], props: p)
        #expect(sorted.map(\.name) == ["dir", "b", "a"])
    }

    @Test func sizeSortAndHiddenLast() {
        var p = ViewProperties(); p.sortRole = .size; p.hiddenLast = true
        let sorted = ItemSorter.sort([item("big", size: 900), item(".h", size: 1), item("small", size: 5)], props: p)
        #expect(sorted.map(\.name) == ["small", "big", ".h"])
    }

    /// Adding items to a sorted list by merging gives the order a full sort would, whatever the sort settings.
    @Test(arguments: [ItemRole.name, .size, .modificationTime, .type])
    func mergingMatchesSortingEverything(role: ItemRole) {
        var rng = SystemRandomNumberGenerator()
        let all = (0..<300).map { i in
            item(
                ["file", "File", "doc", ".x", "Ünïcode"].randomElement(using: &rng)! + "\(Int.random(in: 0..<60, using: &rng))-\(i)",
                dir: Bool.random(using: &rng), size: Int64.random(in: 0..<5, using: &rng),
                mod: Date(timeIntervalSince1970: Double(Int.random(in: 0..<5, using: &rng))))
        }
        for order in [SortOrder.ascending, .descending] {
            var p = ViewProperties()
            p.sortRole = role
            p.sortOrder = order
            p.hiddenLast = Bool.random(using: &rng)
            p.foldersFirst = Bool.random(using: &rng)
            let first = ItemSorter.sort(Array(all.prefix(180)), props: p)
            let merged = ItemSorter.merge(first, adding: Array(all.dropFirst(180)), props: p)
            #expect(merged.map(\.url) == ItemSorter.sort(all, props: p).map(\.url))
        }
    }

    @Test func groupsByNameAndDate() {
        #expect(ItemGrouper.groupName(item("apple"), role: .name) == "A")
        #expect(ItemGrouper.groupName(item("9lives"), role: .name) == "0 - 9")
        #expect(ItemGrouper.groupName(item("_x"), role: .name) == "Others")
        let now = Date()
        #expect(ItemGrouper.groupName(item("t", mod: now), role: .modificationTime, now: now) == "Today")
        #expect(ItemGrouper.groupName(item("y", mod: now.addingTimeInterval(-86400)), role: .modificationTime, now: now) == "Yesterday")
    }
}

@Suite struct FilterTests {
    @Test func plainGlobRegex() throws {
        let plain = try #require(NameFilter(text: "rep").matcher())
        let strict = try #require(NameFilter(text: "rep", caseSensitive: true).matcher())
        let glob = try #require(NameFilter(text: "*.pdf", mode: .glob).matcher())
        let r1 = plain("Report.pdf"), r2 = strict("Report.pdf"), r3 = glob("a.pdf"), r4 = glob("a.pdf.txt")
        #expect(r1)
        #expect(!r2)
        #expect(r3 && !r4)
        #expect(NameFilter(text: "([", mode: .regex).matcher() == nil)
    }
}

@Suite struct FormatTests {
    @Test func sizes() {
        #expect(FileFormat.size(0, units: .binary) == "0 B")
        #expect(FileFormat.size(1536, units: .binary) == "1.5 KiB")
        #expect(FileFormat.size(5 * 1024 * 1024, units: .binary) == "5.0 MiB")
    }

    @Test func names() {
        #expect(FileFormat.duplicateName(for: "a.txt", existing: ["a.txt"]) == "a copy.txt")
        #expect(FileFormat.duplicateName(for: "a.txt", existing: ["a.txt", "a copy.txt"]) == "a copy 2.txt")
        #expect(FileFormat.suggestedName(for: "a.txt", existing: ["a.txt"]) == "a (1).txt")
        #expect(FileFormat.suggestedName(for: "a (1).txt", existing: ["a (1).txt", "a (2).txt"]) == "a (3).txt")
        #expect(FileFormat.permissions(0o755, isDirectory: true) == "drwxr-xr-x")
    }

    @Test func summary() {
        #expect(FileFormat.summary(folders: 2, files: 1, bytes: 2048, selected: false, units: .binary) == "2 folders, 1 file (2.0 KiB)")
        #expect(FileFormat.summary(folders: 1, files: 0, bytes: 0, selected: true) == "1 folder selected")
    }

    @Test func zoom() {
        #expect(ZoomLevels.iconSize(for: 0) == 16)
        #expect(ZoomLevels.iconSize(for: 4) == 64)
        #expect(ZoomLevels.iconSize(for: 16) == 256)
        #expect(ZoomLevels.size(forContinuousLevel: 2.5) == 40)
        #expect(ZoomLevels.continuousLevel(for: 40) == 2.5)
        #expect(ZoomLevels.step(from: 40, by: 1) == 48)
        #expect(ZoomLevels.step(from: 40, by: -1) == 32)
        // Mid-zoom icons come from a handful of step sizes, never smaller than drawn.
        #expect(ZoomLevels.liveRenderSize(for: 48) == 48 && ZoomLevels.liveRenderSize(for: 48.6) == 48)
        #expect(ZoomLevels.liveRenderSize(for: 49) == 64 && ZoomLevels.liveRenderSize(for: 113) == 128)
        #expect(ZoomLevels.liveRenderSize(for: 10) == 16 && ZoomLevels.liveRenderSize(for: 300) == 256)
        #expect(Set((40...200).map { ZoomLevels.liveRenderSize(for: CGFloat($0)) }).count == 11)
        var p = ViewProperties(); p.setIconSize(40, for: .icons)
        #expect(p.iconSize(for: .icons) == 40 && p.zoomLevel(for: .icons) == 2 || p.zoomLevel(for: .icons) == 3)
        let old = #"{"mode":"details","zoom":{"details.preview":3}}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(ViewProperties.self, from: old)
        #expect(decoded.mode == .details && decoded.iconSize(for: .details) == 48 && decoded.foldersFirst)
    }
}

@Suite struct HistoryTests {
    @Test func backForward() {
        var h = NavigationHistory(start: URL(fileURLWithPath: "/a"))
        h.visit(URL(fileURLWithPath: "/b")); h.visit(URL(fileURLWithPath: "/c"))
        #expect(h.goBack()?.path == "/b")
        #expect(h.canGoForward)
        h.visit(URL(fileURLWithPath: "/d"))
        #expect(!h.canGoForward)
        #expect(h.backList.map(\.path) == ["/b", "/a"])
    }
}

struct CountFormattingTests {
    @Test func countsUseOneFormatterAndExplicitLocale() {
        #expect(FileFormat.count(20_041, locale: Locale(identifier: "en_US")) == "20,041")
        #expect(FileFormat.count(20_041, locale: Locale(identifier: "de_DE")) == "20.041")
        #expect(FileFormat.itemCount(20_041) == FileFormat.count(20_041) + " items")
        #expect(FileFormat.summary(folders: 20_041, files: 0, bytes: 0, selected: false) == FileFormat.count(20_041) + " folders")
    }
}

struct StatusMessageFormattingTests {
    @Test func narrowMessagesKeepDestinationWordsWhole() {
        let message = "Copied 1 item to Website · replaced 1"
        #expect(FileFormat.fittingStatusMessage(message) { $0.count <= 100 } == message)
        #expect(FileFormat.fittingStatusMessage(message) { $0.count <= 28 } == "Copied 1 item to Website")
        #expect(FileFormat.fittingStatusMessage(message) { $0.count <= 15 } == "Copied 1 item")
        #expect(FileFormat.fittingStatusMessage(message) { $0.count <= 8 } == "Copied…")
        #expect(FileFormat.fittingStatusMessage(message) { $0.isEmpty } == "")
        #expect(FileFormat.fittingStatusMessage("Finished") { $0.count <= 2 } == "…")
        #expect(FileFormat.fittingStatusMessage("1 file selected (134.1 KiB)") { $0.count <= 18 } == "1 file selected")
        #expect(FileFormat.fittingStatusMessage("1 file selected (134.1 KiB)") { $0.count <= 10 } == "1 file…")
    }
}
