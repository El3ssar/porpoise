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
        #expect(FileFormat.size(0) == "0 B")
        #expect(FileFormat.size(1536) == "1.5 KiB")
        #expect(FileFormat.size(5 * 1024 * 1024) == "5.0 MiB")
    }

    @Test func names() {
        #expect(FileFormat.duplicateName(for: "a.txt", existing: ["a.txt"]) == "a copy.txt")
        #expect(FileFormat.duplicateName(for: "a.txt", existing: ["a.txt", "a copy.txt"]) == "a copy 2.txt")
        #expect(FileFormat.suggestedName(for: "a.txt", existing: ["a.txt"]) == "a (1).txt")
        #expect(FileFormat.suggestedName(for: "a (1).txt", existing: ["a (1).txt", "a (2).txt"]) == "a (3).txt")
        #expect(FileFormat.permissions(0o755, isDirectory: true) == "drwxr-xr-x")
    }

    @Test func summary() {
        #expect(FileFormat.summary(folders: 2, files: 1, bytes: 2048, selected: false) == "2 folders, 1 file (2.0 KiB)")
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

@Suite(.serialized) struct FileJobTests {
    private let scratch: Scratch

    init() throws { scratch = try Scratch("FileJob") }

    @Test func copyWithConflictRenameAndUndo() throws {
        let root = scratch.url
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 300_000).write(to: src.appendingPathComponent("a.bin"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("a.bin"))
        let job = FileJob(kind: .copy, sources: [src.appendingPathComponent("a.bin")], destinationFolder: dst)
        var asked = 0
        job.resolveConflict = { info in
            asked += 1; return ConflictAnswer(.rename(info.suggestedName))
        }
        var last: JobProgress?
        job.onProgress = { last = $0 }
        let undo = try job.run()
        #expect(asked == 1)
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a (1).bin").path))
        #expect(last?.doneBytes == 300_000)
        let u = try #require(undo)
        _ = try FileActions.undo(u)
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("a (1).bin").path))
    }

    @Test func moveAndUndoMove() throws {
        let root = scratch.url
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let job = FileJob(kind: .move, sources: [a.appendingPathComponent("inner")], destinationFolder: b)
        let maybeUndo = try job.run()
        let undo = try #require(maybeUndo)
        #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("inner").path))
        let maybeRedo = try FileActions.undo(undo)
        let redo = try #require(maybeRedo)
        #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("inner").path))
        _ = try FileActions.undo(redo)
        #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("inner").path))
    }

    @Test func refusesCopyIntoItself() throws {
        let root = scratch.url
        let a = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let job = FileJob(kind: .copy, sources: [a], destinationFolder: a.appendingPathComponent("sub"))
        _ = try job.run()
        #expect(job.errors.count == 1)
    }

    @Test func pasteIntoSameFolderMakesCopy() throws {
        let root = scratch.url
        try Data("x".utf8).write(to: root.appendingPathComponent("n.txt"))
        let job = FileJob(kind: .copy, sources: [root.appendingPathComponent("n.txt")], destinationFolder: root)
        _ = try job.run()
        #expect(job.results.map(\.lastPathComponent) == ["n copy.txt"])
    }

    @Test func mergeFolders() throws {
        let root = scratch.url
        let s = root.appendingPathComponent("s/f"), d = root.appendingPathComponent("d/f")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: s.appendingPathComponent("one"))
        try Data("2".utf8).write(to: d.appendingPathComponent("two"))
        let job = FileJob(kind: .copy, sources: [s], destinationFolder: root.appendingPathComponent("d"))
        job.resolveConflict = { _ in ConflictAnswer(.writeInto) }
        _ = try job.run()
        let names = try FileManager.default.contentsOfDirectory(atPath: d.path).sorted()
        #expect(names == ["one", "two"])
    }

    @Test func validateNames() throws {
        let root = scratch.url
        try FileManager.default.createDirectory(at: root.appendingPathComponent("x"), withIntermediateDirectories: true)
        #expect(FileActions.validateName("x", in: root, allowSlash: true)?.isError == true)
        #expect(FileActions.validateName(".h", in: root, allowSlash: true)?.isError == false)
        #expect(FileActions.validateName("ok", in: root, allowSlash: true) == nil)
    }

    @Test func permissionDeniedIsReportedSeparately() throws {
        let root = scratch.url
        let ro = root.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: ro.appendingPathComponent("f"))
        chmod(ro.path, 0o555)
        defer { chmod(ro.path, 0o755) }
        let job = FileJob(kind: .delete, sources: [ro.appendingPathComponent("f")])
        _ = try job.run()
        #expect(job.denied == [ro.appendingPathComponent("f")])
        #expect(job.errors.isEmpty)
    }
}
