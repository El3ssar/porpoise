import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

extension ColumnViewTests {
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
            // Its own modifiers, always: a new event takes the ones held at that moment, and ⇧ held by anything else
            // on the Mac would turn the wheel sideways.
            cg?.flags = kind == .shift ? .maskShift : []
            if let e = cg.flatMap({ NSEvent(cgEvent: $0) }) { content.hitTest(p)?.scrollWheel(with: e) }
        }
    }

    /// A trackpad scroll: fingers resting, the gesture, then its momentum.
    private func gesture(dx: Int32, dy: Int32) -> [NSEvent] {
        func event(_ dx: Int32, _ dy: Int32, phase: Int64 = 0, momentum: Int64 = 0) -> NSEvent? {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            cg?.flags = []
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
        func wheel(_ dy: Int32, _ dx: Int32) -> NSEvent? {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            cg?.flags = []
            return cg.flatMap { NSEvent(cgEvent: $0) }
        }
        let tilt = wheel(0, 3), roll = wheel(3, 0)
        #expect(tilt.map(NestedScrollView.isSideways) == true && roll.map(NestedScrollView.isSideways) == false)
    }

    /// Ten folders down, wider than the pane: a sideways scroll over any column moves the
    /// columns, as in Finder, while an up-and-down one scrolls that column's rows; the keys and a window resize keep
    /// the focused column in view.
    @Test func sidewaysScrollsMoveTheColumnsTenFoldersDown() async throws {
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
            // Sideways it never went: right after, and once anything still due has run.
            #expect(abs(clip.bounds.minX - end) < 0.5, "\(dy): \(clip.bounds.minX) from \(end)")
            #expect(await eventually { !b.isScrolling && abs(clip.bounds.minX - end) < 0.5 }, "\(dy): \(clip.bounds.minX) from \(end)")
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

    // MARK: W-241

    @Test func theTextPreviewUsesTheWholeWideColumn() async throws {
        let s = try tree()
        let (pane, window, _) = try await pane(s.url, width: 1800)
        defer { window.close() }
        let b = try browser(pane)
        pane.list.select(s.path("f.txt"))
        try #require(await eventually { b.preview.information.codePreview.document != nil })
        b.layoutSubtreeIfNeeded()
        b.preview.layoutSubtreeIfNeeded()
        let info = b.preview.information.frame
        #expect(b.preview.frame.width > 1000 && info.width == b.preview.bounds.width)
        #expect(abs(info.midX - b.preview.bounds.midX) <= 1, "\(info) in \(b.preview.bounds)")
        // After the size changes, text previews must use the full column width.
        b.resize(column: b.shownColumns.count - 1, to: ColumnBrowserView.previewMinimum, all: false)
        window.setContentSize(NSSize(width: 800, height: 600))
        pane.layoutSubtreeIfNeeded()
        b.preview.layoutSubtreeIfNeeded()
        #expect(b.preview.information.frame.width == b.preview.bounds.width)
    }

    @Test func theHandleMenuRightSizesColumns() async throws {
        let s = try tree()
        try s.file("A long name that needs a wider column than the others.txt")
        let (pane, window, _) = try await pane(s.url, width: 1400)
        defer { window.close() }
        let b = try browser(pane)
        try #require(await eventually { pane.model.rows.count == 4 })
        pane.list.select(s.path("A"))
        try #require(await eventually { b.after?.model.isLoading == false })
        b.layoutSubtreeIfNeeded()
        let menu = try #require(b.handles[0].menu(for: NSEvent()))
        #expect(menu.items.map(\.title) == ["Right Size This Column", "Right Size All Columns Individually", "Right Size All Columns Equally"])
        func choose(_ i: Int) throws {
            let item = menu.items[i]
            _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        }
        let wide = b.fittingWidth(pane.list), narrow = b.fittingWidth(try #require(b.after).list)
        #expect(wide > narrow)
        try choose(0)
        #expect(b.width(of: s.url) == wide && b.width(of: s.path("A")) == ViewStyleStore.defaultBrowserColumnWidth)
        try choose(1)
        #expect(b.width(of: s.url) == wide && b.width(of: s.path("A")) == narrow)
        try choose(2)
        #expect(b.width(of: s.url) == wide && b.width(of: s.path("A")) == wide && ViewStyleStore().browserColumnWidth == wide)
    }

    @Test func thePreviewColumnCanBeTurnedOff() async throws {
        let s = try tree()
        let (pane, window, _) = try await pane(s.url)
        defer {
            window.close()
            Settings.shared.columnsShowPreview = true
        }
        let b = try browser(pane)
        Settings.shared.columnsShowPreview = false
        pane.list.select(s.path("f.txt"))
        #expect(!b.showsPreview && b.after == nil && b.folders == [s.url])
        // Folders still open their column.
        pane.list.select(s.path("A"))
        #expect(b.after?.url == s.path("A"))
        pane.list.select(s.path("f.txt"))
        Settings.shared.columnsShowPreview = true
        #expect(await eventually { b.showsPreview && b.preview.shownURL == s.path("f.txt") })
        // The View menu's item: checked as the setting is, and only in Column view.
        let wc = MainWindowController(urls: [s.url])
        defer { wc.window?.close() }
        let item = NSMenuItem(title: "Show Preview Column", action: #selector(MainWindowController.togglePreviewColumn(_:)), keyEquivalent: "")
        try #require(await eventually { !wc.view.model.isLoading })
        wc.show(.icons)
        #expect(!wc.validateMenuItem(item))
        wc.show(.columns)
        #expect(wc.validateMenuItem(item) && item.state == .on)
        wc.togglePreviewColumn(nil)
        #expect(!Settings.shared.columnsShowPreview && wc.validateMenuItem(item) && item.state == .off)
        wc.show(.icons)
    }
}
