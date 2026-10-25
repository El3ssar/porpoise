import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

extension ColumnViewTests {
    // MARK: Each column's own size (W-219)

    /// Each folder column's width and icon size, first to last.
    private func sizes(_ b: ColumnBrowserView) -> [[CGFloat]] {
        b.shownColumns.compactMap { v, url in
            guard url != nil, let list = (v as? NSScrollView)?.documentView as? ItemListView else { return nil }
            return [v.frame.width, list.iconSize]
        }
    }

    /// The pane's own column zoomed to `size`, as a pinch or the slider leaves it.
    private func zoom(_ pane: ViewContainer, to size: CGFloat) {
        pane.list.previewZoom(size, anchor: nil, commitAfter: nil)
        pane.list.commitZoom()
    }

    @Test func everyColumnKeepsTheWidthAndIconSizeItWasGiven() async throws {
        let s = try deepTree()
        let (pane, window, _) = try await pane(s.url, width: 1600)
        defer { window.close() }
        let b = try browser(pane)
        try await go(pane, s, to: 5, selecting: "L6")
        #expect(b.folders.count == 7)
        let saved = ViewStyleStore.defaultBrowserColumnWidth
        let icon = pane.list.iconSize
        #expect(sizes(b) == Array(repeating: [saved, icon], count: 7))

        // Each column its own width; the focused one (L5) its own icon size.
        for i in 0..<7 { b.resize(column: i, to: 150 + 20 * CGFloat(i), all: false) }
        zoom(pane, to: 32)
        var expected = (0..<7).map { [150 + 20 * CGFloat($0), icon] }
        expected[5][1] = 32
        #expect(sizes(b) == expected)

        // Moving the focus and selecting along the same path changes none of them.
        key(left, to: pane.list)
        #expect(pane.url.path == s.path(level(4)).path && sizes(b) == Array(expected.prefix(6)))
        key(right, to: pane.list)
        pane.list.select(s.path(level(6)))
        #expect(sizes(b) == expected)
        // (A click on the item already selected there selects nothing new: the column takes the focus as a click
        // elsewhere in it would.)
        b.focus(b.before[2])
        #expect(pane.url.path == s.path(level(2)).path && sizes(b) == Array(expected.prefix(4)))
        try await go(pane, s, to: 5, selecting: "L6")
        #expect(sizes(b) == expected, "the columns closed on the way keep their sizes until another folder opens there")

        // A file only replaces what's after its column, with the preview.
        pane.list.select(s.path("\(level(5))/f.txt"))
        #expect(b.showsPreview && sizes(b) == Array(expected.prefix(6)))
        // The folder again: a new column, at the saved width with its parent's icon size.
        pane.list.select(s.path(level(6)))
        try await listed(b)
        #expect(sizes(b) == Array(expected.prefix(6)) + [[saved, 32]])

        // Another folder in L2's column: the columns after it close, and one opens.
        let l2 = b.before[2]
        try #require(await eventually { l2.model.index(of: s.path("\(level(2))/S")) != nil })
        try click(s.path("\(level(2))/S"), in: l2.list)
        try await listed(b)
        #expect(pane.url.path == s.path(level(2)).path && b.after?.url == s.path("\(level(2))/S"))
        #expect(sizes(b) == Array(expected.prefix(3)) + [[saved, icon]])
    }

    /// ⌘ and the wheel (or a pinch) over a column, its icons only; and where it was.
    private func cmdWheel(over list: ItemListView, in window: NSWindow) throws {
        let p = list.convert(CGPoint(x: list.visibleRect.midX, y: list.visibleRect.midY), to: nil)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        cg.flags = .maskCommand
        cg.location = CGPoint(x: p.x, y: window.frame.height - p.y)
        list.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        list.commitZoom()
    }

    @Test func zoomActsOnTheColumnUnderThePointerAndTheKeysOnTheFocusedOne() async throws {
        let s = try deepTree()
        let (pane, window, _) = try await pane(s.url, width: 1400)
        defer { window.close() }
        let b = try browser(pane)
        try await go(pane, s, to: 2, selecting: "L3")
        let icon = pane.list.iconSize, step = ZoomLevels.step(from: icon, by: 1)
        let entries = pane.history.entries.count

        // ⌘+ and the slider: the focused column (L2).
        zoom(pane, to: 48)
        #expect(sizes(b).map { $0[1] } == [icon, icon, 48, icon])
        // ⌘-wheel or a pinch over the first column, the last one, then the focused one: each zooms itself; the focus
        // and Back stay as they were.
        try cmdWheel(over: b.before[0].list, in: window)
        #expect(sizes(b).map { $0[1] } == [step, icon, 48, icon])
        try cmdWheel(over: try #require(b.after).list, in: window)
        #expect(sizes(b).map { $0[1] } == [step, icon, 48, step])
        try cmdWheel(over: pane.list, in: window)
        let focused = ZoomLevels.step(from: 48, by: 1)
        #expect(sizes(b).map { $0[1] } == [step, icon, focused, step])
        #expect(pane.url.path == s.path(level(2)).path && pane.history.entries.count == entries)
        // With the preview after the focused column, the one under the pointer still.
        pane.list.select(s.path("\(level(2))/f.txt"))
        #expect(b.showsPreview)
        try cmdWheel(over: b.before[1].list, in: window)
        #expect(sizes(b).map { $0[1] } == [step, step, focused])
        // Each keeps its size as the focus moves; a new column takes its parent's.
        key(left, to: pane.list)
        key(right, to: pane.list)
        try await go(pane, s, to: 2, selecting: "S")
        #expect(sizes(b).map { $0[1] } == [step, step, focused, focused])
    }

    @Test func optionResizesEveryColumnAndTheWidthNewOnesOpenAt() async throws {
        let s = try deepTree()
        let (pane, window, _) = try await pane(s.url, width: 1400)
        defer { window.close() }
        let b = try browser(pane)
        try await go(pane, s, to: 2, selecting: "L3")
        b.resize(column: 0, to: 300, all: false)
        b.resize(column: 2, to: 180, all: true)
        #expect(sizes(b).map { $0[0] } == [180, 180, 180, 180] && ViewStyleStore().browserColumnWidth == 180)
        pane.list.select(s.path("\(level(2))/S"))
        try await listed(b)
        #expect(sizes(b).map { $0[0] } == [180, 180, 180, 180])
    }

    @Test func aDoubleClickedFolderStartsTheColumnsAndBackPutsThemBack() async throws {
        let s = try deepTree()
        let (pane, window, recorder) = try await pane(s.url, width: 1400)
        defer { window.close() }
        recorder.navigates = true
        let b = try browser(pane)
        try await go(pane, s, to: 3, selecting: "L4")
        for i in 0..<5 { b.resize(column: i, to: 150 + 20 * CGFloat(i), all: false) }
        // L4 its own icon size: zoomed while focused.
        key(right, to: pane.list)
        zoom(pane, to: 40)
        key(left, to: pane.list)
        let l1 = b.before[1]
        l1.list.scroll(CGPoint(x: 0, y: 300))
        let columns = b.folders, before = sizes(b), icon = b.before[0].list.iconSize
        #expect(columns.count == 5 && before[4] == [230, 40] && pane.model.selection == [s.path(level(4))])

        // A double-click on L4: it's the first column, with its own size.
        try click(s.path(level(4)), in: pane.list, count: 2)
        #expect(pane.url.path == s.path(level(4)).path && b.root.path == s.path(level(4)).path)
        #expect(b.folders.map(\.path) == [s.path(level(4)).path] && sizes(b) == [[230, 40]])
        pane.list.select(s.path(level(5)))
        try await listed(b)
        // (L5 had opened after L4 before its zoom, and keeps the size it showed at.)
        #expect(sizes(b) == [[230, 40], [ViewStyleStore.defaultBrowserColumnWidth, icon]])
        let rerooted = sizes(b)

        // Back: the columns as they were, their sizes, the selection and where each was scrolled.
        pane.goBack()
        try #require(await eventually { !pane.model.rows.isEmpty && b.after != nil })
        try await listed(b)
        #expect(b.root.path == s.url.path && b.folders.map(\.path) == columns.map(\.path))
        #expect(sizes(b) == before && pane.model.selection == [s.path(level(4))])
        #expect(await eventually { b.before[1].list.visibleRect.minY == 300 })
        // Forward: the double-click again.
        pane.goForward()
        try await listed(b)
        #expect(b.root.path == s.path(level(4)).path && sizes(b) == rerooted)
        #expect(pane.model.selection == [s.path(level(5))])

        // From another column: that column's folder starts them.
        pane.goBack()
        let root = b.before[0]
        try #require(await eventually { root.model.index(of: s.path("S")) != nil })
        try click(s.path("S"), in: root.list)
        try click(s.path("S"), in: root.list, count: 2)
        #expect(pane.url.path == s.path("S").path && b.folders.map(\.path) == [s.path("S").path])
        pane.goBack()
        #expect(b.root.path == s.url.path && pane.url.path == s.url.path && pane.model.selection == [s.path("S")])
    }
}
