import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

extension ColumnViewTests {
    @Test func columnsFollowTheArrowKeysAsInFinder() async throws {
        let s = try tree()
        let (pane, window, _) = try await pane(s.url)
        defer { window.close() }
        let b = try browser(pane)
        #expect(b.folders == [s.url] && pane.scroll.isDescendant(of: b))
        #expect(pane.model.props.mode == .columns && pane.model.browsesColumns)

        // A selected folder opens the next column.
        pane.list.select(s.path("A"))
        #expect(b.folders == [s.url, s.path("A")])
        #expect(b.after?.model.location == s.path("A"))

        // →: into it, its first item selected, at once (its column lent its rows).
        try #require(await eventually { b.after?.model.rows.count == 2 })
        key(right, to: pane.list)
        #expect(pane.url.path == s.path("A").path && pane.model.rows.count == 2)
        #expect(pane.model.selection == [s.path("A/A1")])
        #expect(b.before.map(\.url) == [s.url] && b.before[0].pathItem == s.path("A"))
        #expect(b.before[0].model.selection == [s.path("A")])
        #expect(b.after?.url == s.path("A/A1"))

        // → again: a file is selected, and the last column previews it.
        try #require(await eventually { b.after?.model.rows.count == 1 })
        key(right, to: pane.list)
        #expect(pane.url.path == s.path("A/A1").path && pane.model.selection == [s.path("A/A1/deep.txt")])
        #expect(b.showsPreview && b.after == nil && b.preview.shownURL == s.path("A/A1/deep.txt"))
        #expect(b.folders == [s.url, s.path("A"), s.path("A/A1")])
        // → on a file goes nowhere.
        key(right, to: pane.list)
        #expect(pane.url.path == s.path("A/A1").path)

        // ←: back to the column before, the folder we came from selected, its column still open.
        key(left, to: pane.list)
        #expect(pane.url.path == s.path("A").path && pane.model.selection == [s.path("A/A1")])
        #expect(b.after?.url == s.path("A/A1") && !b.showsPreview)
        key(left, to: pane.list)
        #expect(pane.url.path == s.url.path && pane.model.selection == [s.path("A")] && b.before.isEmpty)
        // ← in the first column goes nowhere.
        key(left, to: pane.list)
        #expect(pane.url.path == s.url.path)
        // Several selected: nothing opens after them.
        pane.model.selection = [s.path("A"), s.path("B")]
        #expect(b.after == nil && !b.showsPreview)
        // Up and down move within the column; the next column follows.
        pane.model.selection = []
        pane.list.select(s.path("A"))
        key(125, to: pane.list)
        #expect(pane.model.selection == [s.path("B")] && b.after?.url == s.path("B"))
    }

    @Test func aClickInAnotherColumnMovesTheFocusThere() async throws {
        let s = try tree()
        let (pane, window, recorder) = try await pane(s.url)
        defer { window.close() }
        let b = try browser(pane)
        pane.setURL(s.path("A/A1"))
        #expect(b.folders == [s.url, s.path("A"), s.path("A/A1")])
        let first = b.before[0]
        try #require(await eventually { first.model.index(of: s.path("B")) != nil })

        // B in the first column: the pane goes there, B selected, the keys with it.
        try click(s.path("B"), in: first.list)
        #expect(pane.url.path == s.url.path && pane.model.selection == [s.path("B")])
        #expect(window.firstResponder === pane.list && b.after?.url == s.path("B"))
        #expect(recorder.activations > 0)

        // While the mouse is still down (a drag may start from there), the focus waits for it to come up.
        pane.list.select(s.path("A"))
        var down = true
        ColumnBrowserView.mouseIsDown = { down }
        defer { ColumnBrowserView.mouseIsDown = { false } }
        let waiting = try #require(b.after)
        try #require(await eventually { waiting.model.index(of: s.path("A/a.txt")) != nil })
        try click(s.path("A/a.txt"), in: waiting.list, release: false)
        #expect(pane.url.path == s.url.path && waiting.model.selection == [s.path("A/a.txt")])
        // Its mouse-up moves the focus (no polling for the button).
        down = false
        try click(s.path("A/a.txt"), in: waiting.list, type: .leftMouseUp)
        #expect(await eventually { pane.url.path == s.path("A").path })
        #expect(pane.model.selection == [s.path("A/a.txt")])
        pane.setURL(s.url)

        // The column after the focused one: a click there goes into it.
        pane.list.select(s.path("A"))
        let next = try #require(b.after)
        try #require(await eventually { next.model.index(of: s.path("A/a.txt")) != nil })
        try click(s.path("A/a.txt"), in: next.list)
        #expect(pane.url.path == s.path("A").path && pane.model.selection == [s.path("A/a.txt")])
        #expect(b.showsPreview)

        // A right-click there: the menu is for that item, selected in the focused column.
        let parent = b.before[0]
        try click(s.path("f.txt"), in: parent.list, type: .rightMouseDown)
        #expect(pane.url.path == s.url.path && pane.model.selection == [s.path("f.txt")])
        #expect(recorder.menus.last == s.path("f.txt"))

        // A double-click opens what it's on, from the focused column.
        pane.list.select(s.path("A"))
        let opens = try #require(b.after)
        try #require(await eventually { opens.model.index(of: s.path("A/A1")) != nil })
        try click(s.path("A/A1"), in: opens.list, count: 2)
        #expect(recorder.opened.last == [s.path("A/A1")])

        // Drops onto a folder in another column go to that folder; Quick Look acts on the focused column.
        pane.setURL(s.path("A"))
        let root = b.before[0]
        root.list.delegate?.itemList(root.list, drop: [s.path("f.txt")], onto: s.path("B"), operation: .move, event: nil)
        #expect(recorder.drops.last?.folder == s.path("B"))
        root.list.delegate?.itemListQuickLook(root.list)
        #expect(recorder.quickLooks == 1)
    }

    @Test func theFirstColumnStaysUntilTheViewGoesOutsideIt() async throws {
        let s = try tree()
        let (pane, window, _) = try await pane(s.path("A"))
        defer { window.close() }
        let b = try browser(pane)
        #expect(b.root.path == s.path("A").path)
        pane.setURL(s.path("A/A1"))
        #expect(b.root.path == s.path("A").path && Array(b.folders.prefix(2)) == [s.path("A"), s.path("A/A1")])
        // Back and Forward stay in the columns.
        pane.goBack()
        #expect(pane.url.path == s.path("A").path && b.root.path == s.path("A").path)
        pane.goForward()
        #expect(pane.url.path == s.path("A/A1").path && b.before.count == 1)
        // Up from the first column: its parent becomes the first.
        pane.setURL(s.path("A"))
        pane.goUp()
        // The parent wasn't listed yet: the folder come from is selected once it is.
        try #require(await eventually { !pane.model.selection.isEmpty })
        #expect(pane.url.path == s.url.path && b.root.path == s.url.path && pane.model.selection == [s.path("A")])
        #expect(b.after?.url == s.path("A"))
        // Somewhere else altogether starts the columns there.
        let elsewhere = try Scratch()
        pane.setURL(elsewhere.url)
        #expect(b.root.path == elsewhere.url.path && b.folders.count == 1)

    }

    @Test func eachFolderKeepsItsOwnSettingsAndColumnsIsNotSavedForIt() async throws {
        let s = try tree()
        Settings.store.set(true, forKey: "perFolder")
        var own = ViewProperties()
        own.mode = .icons
        own.sortOrder = .descending
        ViewStyleStore().save(own, for: s.path("A"))
        let (pane, window, _) = try await pane(s.url)
        defer { window.close() }
        let b = try browser(pane)
        pane.list.select(s.path("A"))
        // The column of A lists in A's own order, as columns.
        let a = try #require(b.after)
        try #require(await eventually { a.model.rows.count == 2 })
        #expect(a.model.props.mode == .columns && a.model.props.sortOrder == .descending)
        key(right, to: pane.list)
        #expect(pane.model.props.mode == .columns && pane.columnBrowser === b)
        pane.model.saveProps()
        #expect(ViewStyleStore().style(for: s.path("A")).mode == .icons)
        #expect(ViewStyleStore().style(for: s.url).mode == .columns)

        // Another mode from the menu: the list is back in the pane, and the columns are gone.
        pane.setMode(.details)
        pane.layoutSubtreeIfNeeded()
        #expect(pane.columnBrowser == nil && pane.scroll.superview === pane && pane.list.columnNavigator == nil)
        #expect(pane.scroll.hasHorizontalScroller && !pane.model.browsesColumns)
        #expect(pane.listState.frame == pane.scroll.frame)
    }

    /// A phone's folders (any location a content source lists: a server, a cloud account) show in columns the same way.
    @Test func remoteFoldersBrowseInColumnsThroughTheirSource() async throws {
        let adb = try RecordingTool()
        let serial = "COL" + UUID().uuidString.prefix(8).filter(\.isLetter).uppercased() + "X"
        let root = try #require(URL(string: "adb://\(serial)/"))
        RemoteFS.use(ADBProvider(serial: serial, adb: adb.path), for: root)
        defer { RemoteFS.use(nil, for: root) }
        // Every folder of this phone lists the same: a DCIM folder and a photo.
        try adb.reply(
            """
            total 24
            drwxrwx--x  4 root sdcard_rw 3452 2024-05-01 10:12 .
            drwxrwx--x  4 root sdcard_rw 3452 2024-05-01 10:12 ..
            drwxrws---  2 u0_a1 media_rw 3452 2025-02-03 08:00 DCIM
            -rw-rw----  1 u0_a1 media_rw 2048 2025-02-03 08:01 photo.jpg

            """)
        let (pane, window, _) = try await pane(root)
        defer { window.close() }
        let b = try browser(pane)
        #expect(pane.model.kind == .device && pane.model.props.mode == .columns)
        let dcim = try #require(pane.model.rows.first { $0.item.name == "DCIM" }?.item.url)
        pane.list.select(dcim)
        let next = try #require(b.after)
        try #require(await eventually { next.model.rows.count == 2 })
        #expect(next.model.kind == .device && next.model.rowNames == ["DCIM", "photo.jpg"])
        key(right, to: pane.list)
        // The columns follow the folders' own paths (the phone's root lists its /sdcard).
        let parent = dcim.deletingLastPathComponent()
        #expect(pane.url.path == dcim.path && pane.model.rows.count == 2 && b.before.last?.url.path == parent.path)
        #expect(b.before.last?.pathItem?.path == dcim.path)
        // A remote file shows its preview column too; ← goes back.
        pane.list.select(try #require(pane.model.rows.first { $0.item.name == "photo.jpg" }?.item.url))
        #expect(b.showsPreview)
        key(left, to: pane.list)
        // That folder's column may still be asking the phone: the folder come from is selected once it's listed.
        #expect(pane.url.path == parent.path)
        #expect(await eventually { pane.model.selection.map(\.path) == [dcim.path] })
    }

    @Test func hiddenFilesAndThePreviewFollowTheFocusedColumn() async throws {
        let s = try tree()
        try s.file("A/.secret", "x")
        let (pane, window, _) = try await pane(s.url)
        defer { window.close() }
        let b = try browser(pane)
        pane.list.select(s.path("A"))
        let a = try #require(b.after)
        try #require(await eventually { a.model.rows.count == 2 })
        // Show Hidden Files in the focused column shows them in the others too.
        pane.model.props.showHidden = true
        #expect(await eventually { a.model.rows.count == 3 })
        pane.model.props.showHidden = false
        #expect(await eventually { a.model.rows.count == 2 })
        // The preview is in the window only while it shows (what plays in it stops when it goes).
        pane.list.select(s.path("f.txt"))
        #expect(b.preview.window === window && b.preview.shownURL == s.path("f.txt"))
        pane.list.select(s.path("B"))
        #expect(b.preview.window == nil && b.preview.shownURL == nil)
        pane.list.select(s.path("f.txt"))
        #expect(await eventually { b.preview.window === window && b.preview.shownURL == s.path("f.txt") })
    }

    @Test func columnsScrollToTheLastOneAtOnceWithReduceMotion() async throws {
        let saved = Animator.reducesMotion
        Animator.reducesMotion = { true }
        defer { Animator.reducesMotion = saved }
        let s = try Scratch()
        try s.file("1/2/3/4/5/end.txt")
        let (pane, window, _) = try await pane(s.url, width: 600)
        defer { window.close() }
        let b = try browser(pane)
        pane.setURL(s.path("1/2/3/4/5"))
        try #require(await eventually { pane.model.rows.count == 1 })
        pane.list.select(s.path("1/2/3/4/5/end.txt"))
        let clip = b.strip.contentView
        // The last column (the preview) is in view, without a glide.
        #expect(b.preview.frame.minX >= clip.bounds.minX - 0.5)
        #expect(clip.bounds.minX > 0)
        #expect(pane.scroll.frame.minX >= clip.bounds.minX - 0.5)
    }

    @Test func tenThousandItemsPerColumnMoveTheFocusAtOnce() async throws {
        let s = try Scratch()
        for i in 0..<10_000 { try s.file(String(format: "big/f%05d.txt", i)) }
        try s.file("small/x.txt")
        let (pane, window, _) = try await pane(s.url)
        defer { window.close() }
        let b = try browser(pane)
        pane.list.select(s.path("big"))
        let big = try #require(b.after)
        try #require(await eventually(30) { big.model.rows.count == 10_000 && !big.model.isLoading })

        // Into it and back out, ten times: the rows are there in the same turn, and neither side reads the folder again
        // (the column's listing is current: it's taken as it is).
        var times: [TimeInterval] = []
        for _ in 0..<10 {
            let t0 = Date()
            key(right, to: pane.list)
            #expect(pane.model.rows.count == 10_000 && pane.model.selection == [s.path("big/f00000.txt")])
            #expect(!pane.model.isLoading)
            pane.layoutSubtreeIfNeeded()
            key(left, to: pane.list)
            #expect(pane.model.selection == [s.path("big")] && b.after?.model.rows.count == 10_000)
            #expect(!pane.model.isLoading && b.after?.model.isLoading == false)
            pane.layoutSubtreeIfNeeded()
            times.append(Date().timeIntervalSince(t0))
        }
        // Same-turn assertions above cover listing adoption. PerfBench measures speed with `columnkeys`.
        let median = times.sorted()[times.count / 2]
        print("Column keys median round trip \(median)s")
        // The far end of the column: its row is drawn where it is, and hit testing finds it.
        key(right, to: pane.list)
        key(119, to: pane.list)  // End
        let last = try #require(pane.model.index(of: s.path("big/f09999.txt")))
        #expect(pane.model.currentURL == s.path("big/f09999.txt"))
        #expect(pane.list.visibleRect.intersects(pane.list.frames[last]))
        #expect(pane.list.index(at: CGPoint(x: pane.list.frames[last].midX, y: pane.list.frames[last].midY)) == last)
    }

    @Test func voiceOverReadsTheColumnsAndTheirItems() async throws {
        let s = try tree()
        let (pane, window, recorder) = try await pane(s.url)
        defer { window.close() }
        let b = try browser(pane)
        pane.list.select(s.path("A"))
        #expect(b.accessibilityRole() == .browser && b.accessibilityLabel() == "Columns")
        let next = try #require(b.after)
        #expect(next.scroll.accessibilityLabel() == "A" && next.list.accessibilityLabel() == "A")
        #expect(pane.list.accessibilityRole() == .list && pane.list.accessibilityRowCount() == 3)
        let items = try #require(pane.list.accessibilityChildren() as? [ItemAccessibilityElement])
        let a = try #require(items.first { $0.accessibilityLabel() == "A" })
        #expect(a.isAccessibilitySelected())
        // VO-Shift-M: the item's menu, from the focused column.
        let i = try #require(pane.model.index(of: s.path("f.txt")))
        #expect(pane.list.accessibilityMenu(for: i)?.title == "f.txt" && recorder.menus.last == s.path("f.txt"))
        pane.list.select(s.path("f.txt"))
        #expect(b.preview.accessibilityRole() == .group && b.preview.accessibilityLabel() == "Preview")
    }

    @Test func renameAndTypeAheadWorkInTheFocusedColumn() async throws {
        let s = try tree()
        let (pane, window, _) = try await pane(s.url)
        defer { window.close() }
        pane.list.select(s.path("f.txt"))
        pane.list.beginRename(s.path("f.txt"))
        let field = try #require(pane.list.renameField)
        let i = try #require(pane.model.index(of: s.path("f.txt")))
        // The box sits on the row, within the column.
        #expect(abs(field.frame.midY - pane.list.nameTextRect(i).midY) <= 0.5)
        #expect(field.frame.maxX <= pane.list.frames[i].maxX + 4)
        pane.list.cancelRename()
        // Typing a name's start selects it, and the next column follows.
        pane.list.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "b",
                charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!)
        #expect(pane.model.selection == [s.path("B")] && pane.columnBrowser?.after?.url == s.path("B"))
    }

    // MARK: W-231

    @Test func aClickNeverScrollsAnyColumnUpOrDown() async throws {
        let s = try deepTree()
        let (pane, window, _) = try await pane(s.url, width: 1400)
        defer { window.close() }
        let b = try browser(pane)
        try await go(pane, s, to: 3, selecting: "L4")
        // L1's column (60 files) scrolled to its middle.
        let l1 = b.before[1]
        if l1.list.frames.count != l1.model.rows.count { l1.list.computeLayout() }
        l1.list.scroll(CGPoint(x: 0, y: 300))
        func offsets() -> [CGFloat] { b.shownColumns.compactMap { (($0.view as? NSScrollView)?.documentView as? ItemListView)?.visibleRect.minY } }
        #expect(offsets() == [0, 300, 0, 0, 0])
        // Files in L1's column, one after the other: the focus goes there, and its rows stay where they are.
        for name in ["file 20.txt", "file 22.txt", "file 21.txt"] {
            let list = b.shownColumns.compactMap { ($0.view as? NSScrollView)?.documentView as? ItemListView }[1]
            try click(s.path("L1/\(name)"), in: list)
            #expect(pane.url.path == s.path("L1").path && pane.list.visibleRect.minY == 300, "\(name): \(pane.list.visibleRect.minY)")
            #expect(Array(offsets().prefix(2)) == [0, 300])
        }
        // L1 in the first column (already selected there): L1's column keeps its place as the one after.
        try click(s.path("L1"), in: b.before[0].list)
        #expect(pane.url.path == s.url.path && b.after?.url.lastPathComponent == "L1")
        #expect(offsets() == [0, 300], "\(offsets())")
        // A file shown in it, now the column after the focused one: the focus goes in, its rows stay put.
        try click(s.path("L1/file 25.txt"), in: try #require(b.after).list)
        #expect(pane.url.path == s.path("L1").path && pane.list.visibleRect.minY == 300, "\(pane.list.visibleRect.minY)")
        #expect(offsets() == [0, 300], "\(offsets())")
    }

    @Test func onlyADoubleClickStartsTheColumnsAtAFolder() async throws {
        let s = try deepTree()
        let (pane, window, recorder) = try await pane(s.url, width: 1400)
        defer { window.close() }
        recorder.navigates = true
        let b = try browser(pane)
        func l4() throws -> FileItem { try #require(pane.model.rows.first { $0.item.name == "L4" }?.item) }

        // Spring-loading (a drag resting on the folder) opens it as the next column.
        try await go(pane, s, to: 3, selecting: "L4")
        pane.list.delegate?.itemList(pane.list, open: [try l4()], inNewTab: false)
        #expect(b.root.path == s.url.path && pane.url.path == s.path(level(4)).path && b.folders.count == 5)
        // ⌘↓ and Enter, the same.
        for (code, mods) in [(UInt16(125), NSEvent.ModifierFlags.command), (76, [])] {
            try await go(pane, s, to: 3, selecting: "L4")
            key(code, to: pane.list, mods)
            #expect(b.root.path == s.url.path && pane.url.path == s.path(level(4)).path && b.folders.count == 5, "\(code)")
        }
        // A double-click: the first column.
        try await go(pane, s, to: 3, selecting: "L4")
        try click(s.path(level(4)), in: pane.list, count: 2)
        #expect(b.root.path == s.path(level(4)).path && b.folders.count == 1)
    }

    @Test func aClickOnTheItemSelectedInAnotherColumnMovesTheFocusThere() async throws {
        let s = try deepTree()
        let (pane, window, _) = try await pane(s.url, width: 1400)
        defer { window.close() }
        let b = try browser(pane)
        try await go(pane, s, to: 3, selecting: "L4")
        try click(s.path(level(2)), in: b.before[1].list)
        #expect(pane.url.path == s.path("L1").path && pane.model.selection == [s.path(level(2))])
        #expect(window.firstResponder === pane.list && b.folders.count == 3 && b.after?.url.lastPathComponent == "L2")
    }

    @Test func columnViewIsNeverSplit() async throws {
        let s = try deepTree()
        let a = s.path("L1"), other = s.path("S")
        // In Column view, Split is off (and says why); nothing opens it.
        let wc = MainWindowController(urls: [s.url])
        try #require(await eventually { !wc.view.model.isLoading })
        wc.show(.columns)
        let split = NSMenuItem(title: "Split", action: #selector(MainWindowController.toggleSplit(_:)), keyEquivalent: "")
        #expect(!wc.tab.canSplit && !wc.validateMenuItem(split) && split.toolTip == MainWindowController.noSplitInColumns)
        wc.toggleSplit(nil)
        wc.places(wc.places, open: a, newTab: false, splitView: true)
        #expect(!wc.tab.isSplit && wc.view.url.path == a.path)
        wc.show(.icons)
        #expect(wc.tab.canSplit && wc.validateMenuItem(split))

        // Columns chosen in a split: the active pane stays, alone, where it was.
        let pair = MainWindowController(urls: [a], split: [other])
        try #require(await eventually { pair.tab.containers.allSatisfy { !$0.model.isLoading } })
        pair.tab.setActive(secondary: true)
        pair.show(.columns)
        try #require(await eventually { pair.tab.closing == nil })
        #expect(!pair.tab.isSplit && pair.view.url.path == other.path && pair.view.columnBrowser != nil)

        // A Columns style a pane of a split only inherits (Column view chosen in another window makes it the common
        // style) keeps the split: the pane shows the window's mode until it's alone. Only choosing Column view there
        // collapses the split (above).
        pair.show(.icons)
        let third = MainWindowController(urls: [a], split: [other])
        try #require(await eventually { third.tab.containers.allSatisfy { !$0.model.isLoading } })
        let right = try #require(third.tab.secondary)
        var common = ViewProperties()
        common.mode = .columns
        ViewStyleStore().save(common, for: s.path(level(2)))
        right.setURL(s.path(level(2)))
        third.tab.layoutSubtreeIfNeeded()
        try #require(await eventually { !right.model.isLoading })
        #expect(third.tab.isSplit && right.model.props.mode == .icons && right.columnBrowser == nil)
        right.model.saveProps()
        #expect(ViewStyleStore().style(for: s.path(level(2))).mode == .columns, "the stand-in mode is never saved")
        // Alone again, it shows its Columns style.
        third.tab.setActive(secondary: true)
        third.tab.closeSplit(closeActive: false, animated: false)
        third.tab.layoutSubtreeIfNeeded()
        #expect(!third.tab.isSplit && third.tab.primary === right && right.model.props.mode == .columns && right.columnBrowser != nil)

        // A split saved with a pane in Column view comes back as that pane alone.
        var columns = ViewProperties()
        columns.mode = .columns
        var icons = ViewProperties()
        icons.mode = .icons
        let layout = WindowLayout(tabs: [
            TabLayout(primary: PaneLayout(url: a, props: icons), secondary: PaneLayout(url: other, props: columns), activeIsSecondary: true)
        ])
        let restored = MainWindowController(urls: [s.url])
        #expect(restored.applyLayout(layout))
        #expect(!restored.tab.isSplit && restored.view.url.path == other.path && restored.view.model.props.mode == .columns)
    }

    @Test func tabGoesToTheNextItemByName() async throws {
        let s = try Scratch()
        try s.folder("Zeta")
        try s.file("alpha.txt", "a")
        try s.file("beta.txt", "b")
        let (pane, window, _) = try await pane(s.url)
        defer { window.close() }
        // Shown folders first: Zeta, alpha.txt, beta.txt. By name: alpha.txt, beta.txt, Zeta.
        #expect(pane.model.rows.map(\.item.name) == ["Zeta", "alpha.txt", "beta.txt"])
        let tab: UInt16 = 48
        var seen: [String] = []
        for _ in 0..<4 {
            key(tab, to: pane.list)
            seen.append(pane.model.selection.first?.lastPathComponent ?? "-")
        }
        #expect(seen == ["alpha.txt", "beta.txt", "Zeta", "Zeta"])
        key(tab, to: pane.list, .shift)
        #expect(pane.model.selection == [s.path("beta.txt")])
        // Names that compare the same (Report.txt and Report.pdf with extensions hidden) keep the order shown, so
        // neither is skipped.
        #expect(ItemListView.byName(("Report", 0), ("Report", 1)) && !ItemListView.byName(("Report", 1), ("Report", 0)))
        #expect(ItemListView.byName(("alpha", 5), ("Beta", 0)))
    }

    @Test func voiceOverListsTheBrowsersColumns() async throws {
        // The strip goes to the focused column at once.
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { true }
        defer { Animator.reducesMotion = reduces }
        let s = try deepTree()
        let (pane, window, _) = try await pane(s.url, width: 700)
        defer { window.close() }
        let b = try browser(pane)
        try await go(pane, s, to: 4, selecting: "f.txt")
        b.layoutSubtreeIfNeeded()
        let columns = try #require(b.accessibilityColumns() as? [NSView])
        #expect(columns.count == b.shownColumns.count && zip(columns, b.shownColumns).allSatisfy { $0 === $1.view })
        let visible = try #require(b.accessibilityVisibleColumns() as? [NSView])
        #expect(!visible.isEmpty && visible.count < columns.count && visible.contains { $0 === pane.scroll })
    }
}
