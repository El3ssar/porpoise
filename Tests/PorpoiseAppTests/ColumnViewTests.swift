import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Column view (RM-8): Finder's columns, keys, clicks, widths and preview, on the pane's own list.
@Suite(.serialized, .isolatedSettings) @MainActor struct ColumnViewTests {
    init() {
        _ = NSApplication.shared
        // The machine's own mouse may be in use while the tests run.
        ColumnBrowserView.mouseIsDown = { false }
    }

    /// What the pane asks of its window: recorded.
    private final class Recorder: ViewContainerDelegate {
        var opened: [[URL]] = []
        var menus: [URL?] = []
        var drops: [(urls: [URL], folder: URL)] = []
        var renames: [(URL, String)] = []
        var quickLooks = 0
        var activations = 0
        /// Opening one folder goes into it, as the window does.
        var navigates = false
        func containerDidBecomeActive(_ c: ViewContainer) { activations += 1 }
        func containerDidChangeURL(_ c: ViewContainer) {}
        func containerSelectionChanged(_ c: ViewContainer) {}
        func container(_ c: ViewContainer, open items: [FileItem], inNewTab: Bool) {
            opened.append(items.map(\.url))
            if navigates, items.count == 1, items[0].isBrowsableFolder, !inNewTab { c.setURL(items[0].url) }
        }
        func container(_ c: ViewContainer, menuFor item: FileItem?) -> NSMenu? {
            menus.append(item?.url)
            return NSMenu(title: c.model.selectedItems.map(\.name).joined(separator: ","))
        }
        func container(_ c: ViewContainer, drop urls: [URL], onto folder: URL, operation: NSDragOperation) { drops.append((urls, folder)) }
        func container(_ c: ViewContainer, rename item: FileItem, to name: String) { renames.append((item.url, name)) }
        func container(_ c: ViewContainer, middleClicked item: FileItem) {}
        func containerQuickLook(_ c: ViewContainer) { quickLooks += 1 }
        func containerSearchVisibilityChanged(_ c: ViewContainer) {}
    }

    /// Root ─ A ─ A1 ─ deep.txt, A/a.txt, B, f.txt.
    private func tree() throws -> Scratch {
        let s = try Scratch()
        try s.file("A/A1/deep.txt", "deep")
        try s.file("A/a.txt", "a")
        try s.folder("B")
        try s.file("f.txt", "f")
        return s
    }

    private func pane(_ url: URL, width: CGFloat = 1100) async throws -> (ViewContainer, NSWindow, Recorder) {
        let pane = ViewContainer(url: url)
        let recorder = Recorder()
        pane.delegate = recorder
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        try #require(await eventually { !pane.model.isLoading && !pane.model.rows.isEmpty })
        pane.setMode(.columns)
        pane.layoutSubtreeIfNeeded()
        window.makeFirstResponder(pane.list)
        return (pane, window, recorder)
    }

    private func key(_ code: UInt16, to view: NSView, _ mods: NSEvent.ModifierFlags = []) {
        view.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
    }
    private let right: UInt16 = 124, left: UInt16 = 123

    /// A click on `url`'s row in `list` (down and up), as the user makes it.
    private func click(_ url: URL, in list: ItemListView, count: Int = 1, type: NSEvent.EventType = .leftMouseDown) throws {
        let i = try #require(list.model.index(of: url))
        if list.frames.count != list.model.rows.count { list.computeLayout() }
        let p = list.convert(CGPoint(x: list.frames[i].midX, y: list.frames[i].midY), to: nil)
        let w = try #require(list.window)
        func event(_ t: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: t, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                clickCount: count, pressure: 1)!
        }
        if type == .rightMouseDown {
            _ = list.menu(for: event(.rightMouseDown))
            return
        }
        list.mouseDown(with: event(.leftMouseDown))
        list.mouseUp(with: event(.leftMouseUp))
    }

    private func browser(_ pane: ViewContainer) throws -> ColumnBrowserView { try #require(pane.columnBrowser) }

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
        try click(s.path("A/a.txt"), in: waiting.list)
        #expect(pane.url.path == s.url.path && waiting.model.selection == [s.path("A/a.txt")])
        down = false
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

    @Test func columnsResizeLikeFinders() async throws {
        let s = try tree()
        let (pane, window, _) = try await pane(s.url)
        defer { window.close() }
        let b = try browser(pane)
        pane.list.select(s.path("A"))
        let saved = ViewStyleStore().browserColumnWidth
        #expect(saved == ViewStyleStore.defaultBrowserColumnWidth)
        #expect(pane.scroll.frame.width == saved)

        // One column, by its handle.
        b.resize(column: 0, to: 300, all: false)
        #expect(b.width(of: s.url) == 300 && pane.scroll.frame.width == 300)
        #expect(b.after?.scroll.frame.minX == 301)
        b.resize(column: 0, to: 10, all: false)
        #expect(b.width(of: s.url) == ViewStyleStore.browserColumnWidths.lowerBound)
        // Option: every column, and new ones open at that width.
        b.resize(column: 1, to: 200, all: true)
        #expect(ViewStyleStore().browserColumnWidth == 200 && b.width(of: s.url) == 200 && b.width(of: s.path("A")) == 200)
        // Double-click: as wide as the longest name.
        try s.file("A long name that needs a wider column than this.txt")
        pane.reload()
        try #require(await eventually { pane.model.rows.count == 4 })
        b.fit(column: 0, all: false)
        let w = b.width(of: s.url)
        #expect(w > 200 && w == b.fittingWidth(pane.list))
        let longest = pane.list.textWidth("A long name that needs a wider column than this.txt")
        #expect(w >= longest + ItemListView.chevronWidth + pane.list.iconSize)

        // The handle itself: a drag resizes, VoiceOver steps it.
        b.layoutSubtreeIfNeeded()
        let handle = try #require(b.handles.first)
        #expect(handle.accessibilityRole() == .splitter && (handle.accessibilityValue() as? NSNumber)?.doubleValue == Double(w))
        #expect(handle.accessibilityPerformIncrement())
        #expect(b.width(of: s.url) == w + 20)
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: 10), to: nil)
        func drag(_ t: NSEvent.EventType, dx: CGFloat, count: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(
                with: t, location: CGPoint(x: start.x + dx, y: start.y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        handle.mouseDown(with: drag(.leftMouseDown, dx: 0))
        handle.mouseDragged(with: drag(.leftMouseDragged, dx: -40))
        handle.mouseUp(with: drag(.leftMouseUp, dx: -40))
        #expect(b.width(of: s.url) == w - 20)
        handle.mouseDown(with: drag(.leftMouseDown, dx: 0, count: 2))
        #expect(b.width(of: s.url) == w)

        // The preview column is never narrower than its minimum, and takes what's left of a wide window.
        pane.list.select(s.path("f.txt"))
        let previewIndex = b.shownColumns.count - 1
        b.resize(column: previewIndex, to: 130, all: false)
        #expect(b.width(of: nil) == ColumnBrowserView.previewMinimum)
        #expect(b.preview.frame.maxX >= b.strip.contentView.bounds.width - 1)
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
        // Timing on a shared machine only catches a gross regression (PerfBench measures it: `columnkeys`).
        let median = times.sorted()[times.count / 2]
        #expect(median < 1, "median round trip \(median)s")
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

    @Test func theColumnsRowsAreFullWidthWithAChevronForFolders() async throws {
        let s = try tree()
        let model = try await DirectoryModel.loaded(s.url) { $0.props.mode = .columns }
        let list = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 245, height: 400))
        // As on a Mac set to always show scroll bars (CI's runners): a legacy scroller before the column takes it.
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        ColumnBrowserView.configure(scroll, showing: list)
        list.computeLayout()
        #expect(list.frame.width == scroll.contentView.bounds.width)
        let a = try #require(model.index(of: s.path("A"))), f = try #require(model.index(of: s.path("f.txt")))
        #expect(list.chevronRect(a) != nil && list.chevronRect(f) == nil)
        #expect(list.highlightRect(f).width == list.frames[f].width)
        #expect(list.nameTextRect(a).maxX <= list.chevronRect(a)!.minX)
        // Anywhere on a row is that row.
        #expect(list.index(at: CGPoint(x: list.frames[f].maxX - 2, y: list.frames[f].midY)) == f)
        // Drawn without trouble in both looks.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                model.selection = [s.path("A")]
                #expect(list.picture(ofRow: a) != nil && list.picture(ofRow: f) != nil)
            }
        }
    }

    /// The split view opening and closing over Column view: the panes slide over columns that keep their widths
    /// (nothing flies between the panes, no list is laid out at another width meanwhile, so no row ever stretches), and
    /// each pane keeps its focused column and what follows it in view as it narrows and widens.
    @Test func splitSlidesOverColumnsWithoutStretchingThem() async throws {
        let s = try tree()
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        defer { Animator.reducesMotion = reduces }
        // Every frame is drawn, however slow the machine.
        FrameClock.frameStep = 1.0 / 60
        defer { FrameClock.frameStep = nil }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = PorpoiseTab(url: s.url)
        window.contentView = tab
        tab.frame = window.contentView?.bounds ?? .zero
        let left = tab.primary
        try #require(await eventually { !left.model.isLoading && !left.model.rows.isEmpty })
        left.setMode(.columns)
        tab.layoutSubtreeIfNeeded()
        left.setURL(s.path("A/A1"))
        try #require(await eventually { left.model.index(of: s.path("A/A1/deep.txt")) != nil })
        left.list.select(s.path("A/A1/deep.txt"))
        tab.layoutSubtreeIfNeeded()
        let b = try browser(left)
        #expect(b.folders == [s.url, s.path("A"), s.path("A/A1")] && b.showsPreview)

        /// The folders' columns' widths (the preview fills what's left), and whether the focused column and the last
        /// one are in view.
        func widths(_ b: ColumnBrowserView) -> [CGFloat] { b.shownColumns.filter { $0.url != nil }.map(\.view.frame.width) }
        func endInView(_ b: ColumnBrowserView) -> Bool {
            let shown = b.strip.contentView.bounds
            guard let last = b.shownColumns.last?.view.frame else { return false }
            return b.container.scroll.frame.minX >= shown.minX - 0.5 && last.minX >= shown.minX - 0.5
                && min(last.maxX, shown.maxX) - last.minX >= min(last.width, shown.width) - 0.5
        }
        let before = widths(b)
        let flights = tab.flightsLanded
        /// Runs the slide frame by frame, checking each.
        func slide(_ check: () -> Void) async throws {
            let end = Date().addingTimeInterval(eventualTimeout)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                check()
                try await Task.sleep(for: .milliseconds(5))
            } while (tab.isSliding || tab.closing != nil) && Date() < end
        }

        /// Runs the main run loop (the strip glides there) until `condition` holds.
        func spin(until condition: () -> Bool) async throws {
            let end = Date().addingTimeInterval(eventualTimeout)
            while !condition(), Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(condition())
        }

        tab.openSplit()
        let right = try #require(tab.secondary)
        var frames = 0
        try await slide {
            frames += 1
            #expect(widths(b) == before)
            #expect(right.list.layoutWidthOverride == nil && left.list.layoutWidthOverride == nil)
        }
        #expect(frames > 3)
        try #require(await eventually { !right.model.rows.isEmpty })
        tab.layoutSubtreeIfNeeded()
        // Once the pane stops narrowing, the strip glides on to a column's left edge: none shows cut on the left.
        try await spin { abs(b.strip.contentView.bounds.minX - b.endOrigin) < 0.5 }
        let origin = b.strip.contentView.bounds.minX
        #expect(left.frame.width < 700 && widths(b) == before && endInView(b), "\(b.strip.contentView.bounds)")
        #expect(origin > 0 && b.shownColumns.contains { abs($0.view.frame.minX - origin) < 0.5 }, "\(origin)")
        #expect(tab.flightsLanded == flights)
        #expect(!right.list.transitions.log.contains(.splitOpen) && !left.list.transitions.log.contains(.splitOpen))

        tab.closeSplit(closeActive: true)
        try await slide {
            #expect(widths(b) == before && left.list.layoutWidthOverride == nil)
        }
        tab.layoutSubtreeIfNeeded()
        try await spin { abs(b.strip.contentView.bounds.minX - b.endOrigin) < 0.5 }
        #expect(tab.secondary == nil && tab.closing == nil && tab.flightsLanded == flights)
        #expect(endInView(b) && b.strip.contentView.bounds.minX == 0, "the wider pane shows every column again")
    }

    /// Where the strip rests: at 0 while everything fits; else the last column in view from its left edge, with the
    /// focused one, on a column's left edge (never one cut in half on the left).
    @Test func theStripRestsOnAColumnsEdge() {
        let cols = (0..<4).map { CGRect(x: CGFloat($0) * 201, y: 0, width: 200, height: 400) }
        #expect(ColumnBrowserView.endOrigins(of: cols, focused: 3, visible: 900) == (0, 0))
        // 803 wide in 500: following, the last column's right edge at the strip's (303); resting, on the third column's edge.
        #expect(ColumnBrowserView.endOrigins(of: cols, focused: 3, visible: 500) == (303, 402))
        // The focused column (the second) stays in view: the strip doesn't go past its left edge.
        #expect(ColumnBrowserView.endOrigins(of: cols, focused: 1, visible: 500) == (201, 201))
        // Narrower than the last column: its left edge.
        #expect(ColumnBrowserView.endOrigins(of: cols, focused: 3, visible: 150) == (603, 603))
    }

    /// A scroll as a mouse wheel (its tilt sideways) or ⇧ and the wheel make it, `dx` pointing to the right, sent the
    /// way the window sends it: each event to the view under the pointer, which the columns may have moved.
    private enum Wheel: CaseIterable { case wheel, shift }
    private func scroll(_ kind: Wheel, dx: Int32, dy: Int32 = 0, over view: NSView) {
        guard let content = view.window?.contentView else { return }
        // The middle of what shows of it (it may be cut by the pane's edge).
        let shown = view.visibleRect
        let p = content.convert(view.convert(CGPoint(x: shown.midX, y: shown.midY), to: nil), from: nil)
        for _ in 0..<5 {
            let cg = CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: kind == .shift ? dx / 5 : dy / 5,
                wheel2: kind == .shift ? 0 : dx / 5,
                wheel3: 0)
            if kind == .shift { cg?.flags = .maskShift }
            if let e = cg.flatMap({ NSEvent(cgEvent: $0) }) { content.hitTest(p)?.scrollWheel(with: e) }
        }
    }

    /// A trackpad scroll: fingers resting, the gesture, then its momentum.
    private func gesture(dx: Int32, dy: Int32) -> [NSEvent] {
        func event(_ dx: Int32, _ dy: Int32, phase: Int64 = 0, momentum: Int64 = 0) -> NSEvent? {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            cg?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return cg.flatMap { NSEvent(cgEvent: $0) }
        }
        // CGScrollPhase: began 1, changed 2, ended 4, may begin 128; CGMomentumScrollPhase: begin 1, continue 2, end 3.
        let events =
            [event(0, 0, phase: 128), event(dx / 10, dy / 10, phase: 1)] + (0..<9).map { _ in event(dx / 10, dy / 10, phase: 2) }
            + [event(0, 0, phase: 4), event(dx / 20, dy / 20, momentum: 1)] + (0..<4).map { _ in event(dx / 20, dy / 20, momentum: 2) }
            + [event(0, 0, momentum: 3)]
        return events.compactMap { $0 }
    }

    /// A trackpad gesture is sideways or not from where it starts to the end of its momentum, whatever its fingers do
    /// on the way (AppKit tracks a gesture against the real trackpad, which a test can't drive: the app's debug
    /// bridge `wheel trackpad` posts one through the window server).
    @Test func aTrackpadGestureGoesSidewaysAsItStarts() {
        let sideways = gesture(dx: 200, dy: 30)
        #expect(sideways.count == 18 && sideways[1].phase == .began && sideways.last?.momentumPhase == .ended)
        #expect(sideways.map(NestedScrollView.isSideways) == [false] + Array(repeating: true, count: 17))
        // Down, its fingers drifting sideways at the end: still down, momentum and all.
        let down = gesture(dx: 0, dy: -300)
        #expect(!down.map { NestedScrollView.isSideways($0) }.contains(true))
        let drift = [down[1], sideways[2], sideways[13]]
        #expect(drift.map(NestedScrollView.isSideways) == [false, false, false])
        // A wheel's own clicks each count.
        let tilt = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: 3, wheel3: 0).flatMap {
            NSEvent(cgEvent: $0)
        }
        let roll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 3, wheel2: 0, wheel3: 0).flatMap {
            NSEvent(cgEvent: $0)
        }
        #expect(tilt.map(NestedScrollView.isSideways) == true && roll.map(NestedScrollView.isSideways) == false)
    }

    /// Ten folders down, wider than the pane (alone, or in a split): a sideways scroll over any column moves the
    /// columns, as in Finder, while an up-and-down one scrolls that column's rows; the keys and a window resize keep
    /// the focused column in view.
    @Test(arguments: [false, true]) func sidewaysScrollsMoveTheColumnsTenFoldersDown(split: Bool) async throws {
        let reduces = Animator.reducesMotion
        Animator.reducesMotion = { false }
        defer { Animator.reducesMotion = reduces }
        FrameClock.frameStep = 1.0 / 60
        defer { FrameClock.frameStep = nil }
        // AppKit glides a wheel's clicks with an animation an offscreen window never ends: each click lands at once.
        UserDefaults.standard.set(false, forKey: "NSScrollAnimationEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "NSScrollAnimationEnabled") }
        let s = try Scratch()
        let deep = (1...10).map(String.init).joined(separator: "/")
        for n in 0..<80 { try s.file("\(deep)/file \(n).txt", "\(n)") }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = PorpoiseTab(url: s.url)
        window.contentView = tab
        tab.frame = window.contentView?.bounds ?? .zero
        let pane = tab.primary
        try #require(await eventually { !pane.model.isLoading && !pane.model.rows.isEmpty })
        pane.setMode(.columns)
        if split {
            tab.openSplit()
            try #require(await eventually { !tab.isSliding && tab.secondary.map { !$0.model.rows.isEmpty } == true })
            tab.setActive(secondary: false)
        }
        tab.layoutSubtreeIfNeeded()
        window.makeFirstResponder(pane.list)
        pane.setURL(s.path(deep))
        try #require(await eventually { pane.model.rows.count == 80 })
        pane.list.select(s.path("\(deep)/file 0.txt"))
        let b = try browser(pane)
        let clip = b.strip.contentView
        #expect(b.folders.count == 11 && b.showsPreview)
        #expect(b.strip.documentView.map { $0.frame.width > clip.bounds.width * 2 } == true, "\(clip.bounds)")
        func focusedInView() -> Bool {
            let f = pane.scroll.frame
            return f.minX >= clip.bounds.minX - 0.5 && f.maxX <= clip.bounds.maxX + 0.5
        }
        #expect(await eventually { abs(clip.bounds.minX - b.endOrigin) < 0.5 } && focusedInView())

        for kind in Wheel.allCases {
            // Over the focused column, and over another one in view (the preview, in a narrow pane).
            let other = b.shownColumns.map(\.view).last {
                $0 !== pane.scroll && $0.frame.minX >= clip.bounds.minX && $0.frame.minX < clip.bounds.maxX - 40
            }
            for over in [pane.scroll, try #require(other)] {
                let end = clip.bounds.minX
                scroll(kind, dx: 15, over: over)
                #expect(
                    clip.bounds.minX < end - 50, "\(kind) over \(over === pane.scroll ? "the focused column" : "its parent"): \(clip.bounds.minX)")
                scroll(kind, dx: -30, over: over)
                #expect(clip.bounds.minX > end - 50, "\(kind) back: \(clip.bounds.minX)")
                b.scrollToEnd()
                #expect(await eventually { !b.isScrolling && abs(clip.bounds.minX - end) < 0.5 })
            }
        }
        // Up and down: the columns stay (the column's own rows take it: an offscreen window's columns don't move for a
        // wheel's clicks, the app's do, `wheel line|0|-40` in REPORT-scroll.md).
        // From where the strip rests, once any glide or late settle has run (a loaded machine runs them late).
        try #require(await eventually { !b.isScrolling && abs(clip.bounds.minX - b.endOrigin) < 0.5 })
        let end = clip.bounds.minX
        for dy: Int32 in [15, -15] {
            scroll(.wheel, dx: 0, dy: dy, over: pane.scroll)
            try await Task.sleep(for: .milliseconds(200))
            #expect(!b.isScrolling && abs(clip.bounds.minX - end) < 0.5, "\(dy): \(clip.bounds.minX) from \(end)")
        }
        #expect(!NestedScrollView.isSideways(try #require(gesture(dx: 10, dy: -300).dropFirst().first)))

        // ← all the way up and → back down: the focused column is in view at each step.
        for _ in 0..<10 {
            key(left, to: pane.list)
            #expect(await eventually { !b.isScrolling && focusedInView() }, "\(pane.url.lastPathComponent): \(clip.bounds)")
        }
        #expect(pane.url.standardizedFileURL == s.url.standardizedFileURL && clip.bounds.minX == 0, "\(pane.url.path) \(clip.bounds)")
        for _ in 0..<10 {
            try #require(await eventually { !pane.model.isLoading && pane.model.selection.count == 1 })
            key(right, to: pane.list)
            #expect(await eventually { !b.isScrolling && focusedInView() }, "\(pane.url.lastPathComponent): \(clip.bounds)")
        }
        #expect(pane.url.standardizedFileURL == s.path(deep).standardizedFileURL)
        // The window narrower and wider: still in view, the strip resting on a column's edge.
        for width in [520.0, 1400, 800] {
            window.setContentSize(NSSize(width: width, height: 600))
            tab.layoutSubtreeIfNeeded()
            #expect(await eventually { !b.isScrolling && abs(clip.bounds.minX - b.endOrigin) < 0.5 } && focusedInView(), "\(width): \(clip.bounds)")
        }
    }

    /// A column with nothing in it says so in a quiet line at its top (the focused one has the pane's own message),
    /// which never takes a click; one with rows doesn't.
    @Test func anEmptyColumnSaysSoQuietly() async throws {
        let s = try tree()
        let (pane, window, _) = try await pane(s.url)
        defer { window.close() }
        let b = try browser(pane)
        pane.list.select(s.path("B"))
        let empty = try #require(b.after)
        #expect(await eventually { !empty.model.isLoading && !empty.stateLabel.isHidden })
        #expect(empty.stateLabel.stringValue == "Folder is empty" && empty.stateLabel.state?.isError == false)
        #expect(empty.stateLabel.superview === empty.list && empty.stateLabel.frame.minY > ItemListView.columnsTop)
        #expect(empty.stateLabel.frame.width > 0 && empty.stateLabel.frame.maxX <= empty.list.bounds.width)
        #expect(empty.stateLabel.hitTest(CGPoint(x: empty.stateLabel.frame.midX, y: empty.stateLabel.frame.midY)) == nil)

        pane.list.select(s.path("A"))
        let full = try #require(b.after)
        #expect(await eventually { full.model.rows.count == 2 })
        #expect(full.stateLabel.isHidden)
    }

    // MARK: Each column's own size (W-219)

    /// Six folders deep: L1/…/L6, and in the root and each of them a folder S and a file f.txt; L1 has 60 more files.
    private func deepTree() throws -> Scratch {
        let s = try Scratch()
        try s.file("f.txt", "0")
        try s.folder("S")
        for k in 1...6 {
            try s.file("\(level(k))/f.txt", "\(k)")
            try s.folder("\(level(k))/S")
        }
        for n in 0..<60 { try s.file("L1/file \(n).txt", "\(n)") }
        return s
    }

    /// The path of the folder `depth` levels down: L1/…/L`depth`.
    private func level(_ depth: Int) -> String { (1...max(1, depth)).map { "L\($0)" }.joined(separator: "/") }

    /// Each folder column's width and icon size, first to last.
    private func sizes(_ b: ColumnBrowserView) -> [[CGFloat]] {
        b.shownColumns.compactMap { v, url in
            guard url != nil, let list = (v as? NSScrollView)?.documentView as? ItemListView else { return nil }
            return [v.frame.width, list.iconSize]
        }
    }

    /// Every column shown has listed its folder.
    private func listed(_ b: ColumnBrowserView) async throws {
        try #require(await eventually { (b.before + [b.after].compactMap { $0 }).allSatisfy { !$0.model.isLoading } })
    }

    /// The pane in the folder `depth` levels down, `item` (in it) selected once it has listed.
    private func go(_ pane: ViewContainer, _ s: Scratch, to depth: Int, selecting item: String) async throws {
        pane.setURL(depth == 0 ? s.url : s.path(level(depth)))
        let u = s.path(depth == 0 ? item : "\(level(depth))/\(item)")
        try #require(await eventually { pane.model.index(of: u) != nil })
        pane.list.select(u)
        try await listed(try browser(pane))
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

    @Test func zoomChangesTheFocusedColumnOnly() async throws {
        let s = try deepTree()
        let (pane, window, _) = try await pane(s.url, width: 1400)
        defer { window.close() }
        let b = try browser(pane)
        try await go(pane, s, to: 2, selecting: "L3")
        let icon = pane.list.iconSize
        zoom(pane, to: 48)
        #expect(sizes(b).map { $0[1] } == [icon, icon, 48, icon])

        // ⌘ and the wheel over another column: the focused column zooms, the focus and Back stay as they were.
        let entries = pane.history.entries.count
        let first = b.before[0]
        let p = first.list.convert(CGPoint(x: first.list.visibleRect.midX, y: first.list.visibleRect.midY), to: nil)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        cg.flags = .maskCommand
        cg.location = CGPoint(x: p.x, y: window.frame.height - p.y)
        first.list.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        pane.list.commitZoom()
        let zoomed = ZoomLevels.step(from: 48, by: 1)
        #expect(pane.url.path == s.path(level(2)).path && pane.history.entries.count == entries)
        #expect(zoomed != 48 && sizes(b).map { $0[1] } == [icon, icon, zoomed, icon])
        // The focused column's zoom stays its own when the focus moves on.
        key(left, to: pane.list)
        #expect(pane.list.iconSize == icon && b.sizes.map(\.iconSize) == [icon, icon, zoomed, icon])
        key(right, to: pane.list)
        // A new column takes its parent's size.
        try await go(pane, s, to: 2, selecting: "S")
        #expect(sizes(b).map { $0[1] } == [icon, icon, zoomed, zoomed])
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

    @Test func eachPaneOfASplitSizesItsOwnColumns() async throws {
        let s = try deepTree()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = PorpoiseTab(url: s.url)
        window.contentView = tab
        tab.frame = window.contentView?.bounds ?? .zero
        let left = tab.primary
        try #require(await eventually { !left.model.isLoading && !left.model.rows.isEmpty })
        left.setMode(.columns)
        tab.openSplit()
        try #require(await eventually { !tab.isSliding && tab.secondary.map { !$0.model.rows.isEmpty } == true })
        let right = try #require(tab.secondary)
        right.setMode(.columns)
        tab.layoutSubtreeIfNeeded()
        for pane in [left, right] { try await go(pane, s, to: 2, selecting: "L3") }
        let l = try browser(left), r = try browser(right)
        let icon = left.list.iconSize, saved = ViewStyleStore.defaultBrowserColumnWidth
        l.resize(column: 1, to: 300, all: false)
        zoom(right, to: 48)
        #expect(sizes(l) == [[saved, icon], [300, icon], [saved, icon], [saved, icon]])
        #expect(sizes(r) == [[saved, icon], [saved, icon], [saved, 48], [saved, icon]])
    }
}
