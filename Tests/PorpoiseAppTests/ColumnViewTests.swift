import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Column view (RM-8): Finder's columns, keys, clicks, widths and preview, on the pane's own list.
@Suite(.serialized, .isolatedSettings) @MainActor struct ColumnViewTests {
    init() { _ = NSApplication.shared }

    /// What the pane asks of its window: recorded.
    private final class Recorder: ViewContainerDelegate {
        var opened: [[URL]] = []
        var menus: [URL?] = []
        var drops: [(urls: [URL], folder: URL)] = []
        var renames: [(URL, String)] = []
        var quickLooks = 0
        var activations = 0
        func containerDidBecomeActive(_ c: ViewContainer) { activations += 1 }
        func containerDidChangeURL(_ c: ViewContainer) {}
        func containerSelectionChanged(_ c: ViewContainer) {}
        func container(_ c: ViewContainer, open items: [FileItem], inNewTab: Bool) { opened.append(items.map(\.url)) }
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
}
