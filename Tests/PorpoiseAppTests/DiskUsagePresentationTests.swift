import AppKit
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized) @MainActor struct DiskUsagePresentationTests {
    init() { _ = NSApplication.shared }

    @Test func theFooterSaysWhereFromTheFolderScanned() {
        let root = URL(fileURLWithPath: "/Users/u/Demo")
        #expect(DiskUsageWindow.place(of: root, in: [root]) == "Demo")
        #expect(DiskUsageWindow.place(of: root.appendingPathComponent("Photos/2024"), in: [root]) == "Demo › Photos › 2024")
        #expect(DiskUsageWindow.place(of: URL(fileURLWithPath: "/Users/u/Demo2"), in: [root]) == "Demo2")
        #expect(DiskUsageWindow.place(of: nil, in: [root]) == "Selection")
        #expect(DiskUsageWindow.place(of: URL(fileURLWithPath: "/Library"), in: [URL(fileURLWithPath: "/")]) == "/ › Library")
    }

    @Test func zeroCountsAreLeftOut() {
        let quiet = DiskUsageWindow.summary(place: "Demo", logical: 0, allocated: 0, files: 1, hardLinkAliases: 0, errors: 0)
        #expect(quiet.hasPrefix("Demo · ") && quiet.hasSuffix(" · 1 file"))
        #expect(!quiet.contains("alias") && !quiet.contains("error"))
        let busy = DiskUsageWindow.summary(place: "Demo", logical: 0, allocated: 0, files: 20, hardLinkAliases: 2, errors: 1)
        #expect(busy.hasSuffix("20 files · 2 hard-link aliases · 1 error"))
    }

    @Test func tilesAreColoredByWhatTheyHold() {
        typealias Kind = DiskTreemapView.Kind
        #expect(Kind(name: "Photos", folder: true) == .folder)
        #expect(Kind(name: "IMG_1.jpg", folder: false) == .image)
        #expect(Kind(name: "clip.mp4", folder: false) == .video)
        #expect(Kind(name: "tone.m4a", folder: false) == .audio)
        #expect(Kind(name: "Backup.zip", folder: false) == .archive)
        #expect(Kind(name: "disk.img", folder: false) == .archive)
        #expect(Kind(name: "Roadmap.pdf", folder: false) == .document)
        #expect(Kind(name: "notes.txt", folder: false) == .document)
        #expect(Kind(name: "README", folder: false) == .other)
        // Each kind its own color.
        #expect(Set(Kind.allCases.map { $0.color.hexString }).count == Kind.allCases.count)
    }

    @Test func theErrorsButtonShowsOnlyWithErrors() throws {
        let scratch = try Scratch()
        let window = DiskUsageWindow(roots: [scratch.url])
        defer { window.close() }
        #expect(window.errorsButton.isHidden)
        window.errors = ["/x: Permission denied"]
        #expect(!window.errorsButton.isHidden && window.errorsButton.title == "Errors (1)…")
        window.errors = []
        #expect(window.errorsButton.isHidden)
    }

    /// UI-10: a real toolbar (Back as a chevron, the actions as symbols, the measure as a pop-up), the progress row only
    /// while scanning, and centred empty states for the map and the list.
    @Test func diskUsageLooksFinished() async throws {
        let scratch = try Scratch()
        let folder = scratch.url.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: folder.appendingPathComponent("a.jpg"))
        try FileManager.default.createDirectory(at: scratch.url.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let w = DiskUsageWindow(roots: [scratch.url])
        let window = try #require(w.window)
        defer { window.close() }
        let bar = try #require(w.bar)
        // It opens at its own size; nothing in it asks for more.
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(window.contentRect(forFrameRect: window.frame).height - 740) < 1, "\(window.frame)")
        #expect(window.toolbar === bar.toolbar)
        #expect(bar.toolbar.items.map(\.itemIdentifier.rawValue) == ["back", "NSToolbarFlexibleSpaceItem", "metric", "rescan", "reveal", "trash"])
        #expect(bar.item("back")?.image?.name() == nil && bar.item("back")?.image != nil)
        #expect(w.toolbar.isHidden, "no row of bordered buttons in the content")
        #expect(await eventually { !w.busy && !w.rows.isEmpty })
        #expect(w.progressRow.isHidden, "no idle progress bar or disabled Cancel")
        // Nothing selected to reveal or trash.
        for id in ["reveal", "trash"] { #expect(bar.validateToolbarItem(try #require(bar.item(id))) == false, "\(id)") }
        #expect(bar.validateToolbarItem(try #require(bar.item("rescan"))))
        // Into the empty folder: the list and the map say so, centred.
        let empty = try #require(w.rows.firstIndex { $0.first == "Empty" })
        w.table.selectRowIndexes([empty], byExtendingSelection: false)
        #expect(bar.validateToolbarItem(try #require(bar.item("reveal"))))
        let id = try #require(w.itemID(named: "Empty"))
        w.map.activate?(id)
        #expect(w.rows.isEmpty)
        #expect(!w.emptyState.isHidden && w.emptyState.state?.title == "Folder is empty")
        // Centred over the list, at the list's size.
        window.contentView?.layoutSubtreeIfNeeded()
        let list = try #require(w.table.enclosingScrollView)
        let over = w.emptyState.convert(w.emptyState.bounds, to: nil), under = list.convert(list.bounds, to: nil)
        #expect(abs(over.midX - under.midX) < 1 && abs(over.width - under.width) < 1 && over.height > 100, "\(over) over \(under)")
        // The list says it is empty; the map doesn't say it again, nor leave a blank band: it steps aside.
        #expect(w.map.isHidden)
        #expect(bar.validateToolbarItem(try #require(bar.item("back"))))
        bar.perform("back")
        #expect(!w.rows.isEmpty && w.emptyState.isHidden && w.map.emptyState.isHidden && !w.map.isHidden)
        // A level whose items are all empty: the map says why it draws nothing, the list lists them.
        let photos = try #require(w.itemID(named: "Photos"))
        w.map.activate?(photos)
        w.map.items = w.map.items.map { ($0.0, $0.1, 0) }
        #expect(!w.map.emptyState.isHidden && w.map.emptyState.state?.title == "Nothing here takes up space")
        // One footer line, secondary.
        #expect(w.status.textColor == Theme.windowTextInactive)
        #expect(!w.stack.arrangedSubviews.contains { ($0 as? NSTextField)?.stringValue == DiskUsageWindow.hint })
    }
}
