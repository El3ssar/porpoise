import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Work that ends after the person has moved on, and state kept past a change (W-240, from the W-235 audit): each
/// lands where the person is now, or not at all.
@Suite(.serialized, .isolatedSettings) @MainActor struct StaleStateTests {
    init() { _ = NSApplication.shared }

    private func pane(_ url: URL, width: CGFloat = 800) async throws -> (ViewContainer, NSWindow) {
        let pane = ViewContainer(url: url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        try #require(await eventually { !pane.model.isLoading && !pane.model.rows.isEmpty })
        pane.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    private func mouse(_ type: NSEvent.EventType, at p: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
    }

    /// #5: a press remembers its item, not its row: a file appearing above it during the press changes nothing.
    @Test func aPressActsOnItsItemThoughARowAppearsAboveIt() async throws {
        let s = try Scratch()
        try s.file("b.txt", "b")
        try s.file("c.txt", "c")
        let (pane, window) = try await pane(s.url)
        defer { window.close() }
        pane.setMode(.details)
        pane.layoutSubtreeIfNeeded()
        let list = pane.list
        list.computeLayout()
        pane.model.selection = [s.path("b.txt"), s.path("c.txt")]
        let i = try #require(pane.model.index(of: s.path("c.txt")))
        let p = list.convert(CGPoint(x: list.frames[i].midX, y: list.frames[i].midY), to: nil)
        list.mouseDown(with: mouse(.leftMouseDown, at: p, in: window))
        // a.txt arrives above while the button is down.
        try s.file("a.txt", "a")
        pane.reload()
        try #require(await eventually { pane.model.rows.count == 3 })
        list.mouseUp(with: mouse(.leftMouseUp, at: p, in: window))
        #expect(pane.model.selection == [s.path("c.txt")], "the click lands on c.txt, not on the row it had")
    }

    /// #14: the wheel over a crumb lists the sibling folders off the main thread, and once per turn of the wheel.
    @Test func theCrumbWheelListsSiblingsOffTheMainThread() async throws {
        let s = try Scratch()
        for name in ["A", "B", "C"] { try s.folder(name) }
        final class Recorder: BreadcrumbDelegate {
            var went: [URL] = []
            func breadcrumb(_ b: BreadcrumbView, navigateTo url: URL, newTab: Bool) {
                went.append(url)
                b.url = url
            }
            func breadcrumbActivated(_ b: BreadcrumbView) {}
            func breadcrumb(_ b: BreadcrumbView, drop urls: [URL], onto folder: URL, operation: NSDragOperation) {}
        }
        nonisolated(unsafe) var onMain: [Bool] = []
        let real = BreadcrumbView.listFolders
        BreadcrumbView.listFolders = {
            onMain.append(Thread.isMainThread); return real($0)
        }
        defer { BreadcrumbView.listFolders = real }
        let crumbs = BreadcrumbView(frame: CGRect(x: 0, y: 0, width: 700, height: 28))
        let window = NSWindow(contentRect: crumbs.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = crumbs
        defer { window.close() }
        let recorder = Recorder()
        crumbs.delegate = recorder
        crumbs.url = s.path("A")
        crumbs.layoutSubtreeIfNeeded()
        func tick() throws {
            let r = try #require(crumbs.crumbRect(crumbs.url))
            let p = crumbs.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
            // A window-less event's location reads as its point in the window.
            cg.location = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
            crumbs.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        }
        try tick()
        #expect(recorder.went.isEmpty, "nothing listed on the main thread: the step waits for the list")
        try #require(await eventually { recorder.went.map(\.lastPathComponent) == ["B"] })
        try tick()
        #expect(recorder.went.map(\.lastPathComponent) == ["B", "C"], "the next tick uses the list it read")
        #expect(onMain == [false])
    }

    /// #16: an archive extracted after the pane went elsewhere doesn't take it back.
    @Test func anArchiveExtractedLateWaitsInTheMessageBar() async throws {
        let s = try Scratch()
        try s.folder("Contents")
        try s.folder("Elsewhere")
        let (pane, window) = try await pane(s.url)
        defer { window.close() }
        let asked = pane.navigations
        MainWindowController.extracted(.success(s.path("Contents")), archive: "big.xz", in: pane, asked: asked)
        #expect(pane.url.path == s.path("Contents").path)
        let later = pane.navigations
        pane.setURL(s.path("Elsewhere"))
        MainWindowController.extracted(.success(s.path("Contents")), archive: "big.xz", in: pane, asked: later)
        #expect(pane.url.path == s.path("Elsewhere").path && pane.messageBar.text.contains("big.xz") && pane.messageBar.actionFrame != nil)
        pane.messageBar.performAction()
        #expect(pane.url.path == s.path("Contents").path)
    }

    /// #17: a share mounted (or failing) after the pane went elsewhere neither moves it nor shows its error there.
    @Test func aShareMountedLateLeavesThePaneWhereItIs() async throws {
        let s = try Scratch()
        try s.folder("Share")
        try s.folder("Elsewhere")
        let (pane, window) = try await pane(s.url)
        defer { window.close() }
        let asked = pane.navigations
        pane.setURL(s.path("Elsewhere"))
        var went: URL?
        pane.mounted(.success(s.path("Share")), asked: asked) {
            went = $1; $0.setURL($1)
        }
        #expect(went == nil && pane.url.path == s.path("Elsewhere").path && pane.messageBar.text.contains("Share"))
        pane.messageBar.dismiss()
        pane.mounted(.failure(CocoaError(.fileReadNoPermission)), asked: asked) { _, _ in }
        #expect(pane.messageBar.isHidden, "the error of a share left behind isn't shown over another folder")
        pane.mounted(.success(s.path("Share")), asked: pane.navigations) {
            went = $1; $0.setURL($1)
        }
        #expect(went?.path == s.path("Share").path && pane.url.path == s.path("Share").path)
    }

    /// #18: a message's handlers go with it: a pane closed after a message no longer lives on in its bar.
    @Test func aDismissedMessageLetsGoOfItsHandlers() {
        final class Owner {}
        weak var gone: Owner?
        let bar = MessageBar()
        do {
            let owner = Owner()
            gone = owner
            bar.show("Moved to the Trash", error: false, action: "Undo") { _ = owner }
            bar.closeHandler = { _ = owner }
        }
        #expect(gone != nil)
        bar.dismiss()
        #expect(gone == nil)
    }

    /// W7: the mouse's Back and Forward buttons over the tab bar don't close the tab; the middle button does.
    @Test func sideButtonsOverATabDontCloseIt() {
        final class Recorder: TabBarDelegate {
            var closed: [Int] = []
            func tabBar(_ bar: TabBarView, select index: Int) {}
            func tabBar(_ bar: TabBarView, close index: Int) { closed.append(index) }
            func tabBarNewTab(_ bar: TabBarView, duplicate index: Int?) {}
            func tabBar(_ bar: TabBarView, move from: Int, to: Int) {}
            func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu? { nil }
            func tabBar(_ bar: TabBarView, folderAt index: Int) -> URL? { nil }
            func tabBar(_ bar: TabBarView, drop urls: [URL], onto index: Int, operation: NSDragOperation) {}
            func tabBar(_ bar: TabBarView, detach index: Int) {}
        }
        let bar = TabBarView(frame: CGRect(x: 0, y: 0, width: 600, height: 30))
        let window = NSWindow(contentRect: bar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        defer { window.close() }
        let recorder = Recorder()
        bar.delegate = recorder
        bar.titles = ["One", "Two"]
        bar.layoutSubtreeIfNeeded()
        let p = bar.convert(CGPoint(x: 40, y: bar.bounds.midY), to: nil)
        for button in [3, 4, 2] {
            let e = NSEvent.otherMouseEvent(at: p, button: button, window: window)
            bar.otherMouseUp(with: e)
        }
        #expect(recorder.closed == [0])
    }

    /// W8: Back works with a text field focused, as Forward does.
    @Test func backWorksWhileTypingInAField() async throws {
        let s = try Scratch()
        try s.folder("A")
        let wc = MainWindowController(urls: [s.url])
        defer { wc.window?.close() }
        try #require(await eventually { !wc.view.model.isLoading })
        wc.view.setURL(s.path("A"))
        let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        wc.window?.contentView?.addSubview(field)
        wc.window?.makeFirstResponder(field)
        #expect(wc.window?.firstResponder === field)
        wc.goBack(nil)
        #expect(wc.view.url.path == s.url.path)
        wc.goForward(nil)
        #expect(wc.view.url.path == s.path("A").path)
    }

    /// W11: the menu bar's submenus come from the browser window in front, not the first one opened.
    @Test func theMenuBarFollowsTheBrowserInFront() async throws {
        let s = try Scratch()
        let first = MainWindowController(urls: [s.url]), second = MainWindowController(urls: [s.url])
        defer {
            first.window?.close()
            second.window?.close()
        }
        #expect(AppDelegate.menuBrowser(main: second.window, windows: [first, second]) === second)
        // Another kind of window in front of every browser: the first one, as before.
        #expect(AppDelegate.menuBrowser(main: nil, windows: [first, second]) === first)
    }

    /// W20: a failed eject puts every pane back where it was; one sent elsewhere since stays there.
    @Test func aFailedEjectPutsThePanesBack() async throws {
        let s = try Scratch()
        try s.file("Disk/Work/w.txt", "w")
        try s.folder("Other")
        let (a, wa) = try await pane(s.path("Disk/Work"))
        let (b, wb) = try await pane(s.path("Disk"))
        defer {
            wa.close()
            wb.close()
        }
        var left = VolumeLeave()
        for p in [a, b] {
            let was = p.url
            p.setURL(FileManager.default.homeDirectoryForCurrentUser)
            left.panes.append((VolumeLeave.Weak(p), was, p.navigations))
        }
        b.setURL(s.path("Other"))
        left.putBack()
        #expect(a.url.path == s.path("Disk/Work").path && b.url.path == s.path("Other").path)
    }

    /// V6: an app-wide error shows in the pane being looked at, not in every tab of every window.
    @Test func statusErrorsShowInTheFrontPaneOnly() async throws {
        let s = try Scratch()
        let front = MainWindowController(urls: [s.url, s.url]), back = MainWindowController(urls: [s.url])
        defer {
            front.window?.close()
            back.window?.close()
        }
        try #require(await eventually { (front.tabs + back.tabs).allSatisfy { !$0.primary.model.isLoading } })
        let real = ViewContainer.frontBrowserWindow
        ViewContainer.frontBrowserWindow = { front.window }
        defer { ViewContainer.frontBrowserWindow = real }
        StatusCenter.error("Could not open “x”.")
        #expect(front.view.messageBar.text == "Could not open “x”." && !front.view.messageBar.isHidden)
        let others = front.tabs.filter { $0 !== front.tab }.map(\.primary) + [back.view]
        #expect(others.allSatisfy { $0.messageBar.isHidden }, "\(others.map(\.messageBar.text))")
    }

    /// V13: an item Git ignores is drawn at half strength once (row and icon together), like a hidden one.
    @Test func ignoredItemsAreDimmedOnce() async throws {
        let f = try await Task.detached {
            let f = try LocalGitFixture()
            try f.scratch.file(".gitignore", "ignored/\n")
            try f.scratch.file("ignored/file", "x")
            try f.scratch.file(".hidden", "x")
            return f
        }.value
        let pane = ViewContainer(url: f.url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        defer { window.close() }
        pane.model.props.showHidden = true
        try #require(await eventually { !pane.model.isLoading && pane.model.gitStatus != nil })
        let ignored = try #require(pane.model.rows.first { $0.item.name == "ignored" }?.item)
        try #require(await eventually { pane.list.gitBadge(ignored) == .ignored })
        #expect(pane.list.rowDimmed(ignored, cloud: pane.model.shownCloud(for: ignored).state) && pane.list.iconAlpha(ignored) == 1)
        let hidden = try #require(pane.model.rows.first { $0.item.name == ".hidden" }?.item)
        #expect(!pane.list.rowDimmed(hidden, cloud: pane.model.shownCloud(for: hidden).state) && pane.list.iconAlpha(hidden) == 0.5)
    }

    /// The search guard: results of a search that was replaced are dropped when they land.
    @Test func aReplacedSearchsResultsAreDropped() async throws {
        let s = try Scratch()
        try s.file("alpha.txt", "a")
        try s.file("beta.txt", "b")
        let (pane, window) = try await pane(s.url)
        defer {
            pane.closeSearch()
            window.close()
        }
        var runners: [SearchRunner] = []
        pane.configureSearchForTesting = { runner in
            runner.usesIndex = false
            runners.append(runner)
        }
        pane.showSearch()
        pane.searchBar(pane.searchBar, search: "alpha", everywhere: false, contents: false)
        pane.searchBar(pane.searchBar, search: "beta", everywhere: false, contents: false)
        try #require(runners.count == 2)
        let stale = try #require(FileItem.load(s.path("alpha.txt")))
        runners[0].update([stale], true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!pane.model.rows.contains { $0.item.name == "alpha.txt" && pane.model.isSearching })
    }
}

extension NSEvent {
    /// A press of mouse button `button` (2: middle, 3 and 4: Back and Forward) released at `p`.
    static func otherMouseEvent(at p: CGPoint, button: Int, window: NSWindow) -> NSEvent {
        let cg = CGEvent(
            mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
        cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        cg.location = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
        return NSEvent(cgEvent: cg)!
    }
}
