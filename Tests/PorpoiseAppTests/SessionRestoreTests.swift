import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// The session: how it is stored, how earlier sessions read, what is left out when a location is gone, and windows
/// that come back as they were before they are shown (Tests/UI/restore_after_kill.py does it across a SIGKILL).
@MainActor @Suite(.serialized, .isolatedSettings) struct SessionRestoreTests {
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }
    private func pane(_ p: String) -> PaneLayout { PaneLayout(url: p.contains(":") ? URL(string: p)! : url(p)) }

    @Test func storedOneLayoutPerWindowAndReadsOlderSessions() throws {
        let session = SessionState(windows: [
            WindowLayout(
                tabs: [
                    TabLayout(primary: PaneLayout(url: url("/tmp/a"), scroll: [0, 840])),
                    TabLayout(primary: pane("/tmp/b"), secondary: pane("/tmp/c"), activeIsSecondary: true, splitFraction: 0.35),
                ], activeTab: 1, panels: PanelLayout(places: false, information: true), frame: [400, 220, 1000, 640]),
            WindowLayout(tabs: [TabLayout(primary: pane("ftp://example.com/pub/"))]),
        ])
        #expect(SessionState(stored: session.stored) == session)
        // A window that can't be read (a newer format) leaves the others.
        var newer = try #require(try JSONSerialization.jsonObject(with: session.stored[0]) as? [String: Any])
        newer["version"] = WindowLayout.currentVersion + 1
        let mixed = [try JSONSerialization.data(withJSONObject: newer), session.stored[1]]
        #expect(SessionState(stored: mixed).windows == [session.windows[1]])

        // What earlier versions saved: tabs, splits, the frame and the active tab; the panels last shown.
        Settings.store.set(true, forKey: "panel.info")
        let old: [[[String: String]]] = [
            [
                ["url": "file:///tmp/a/", "frame": "{{10, 20}, {800, 600}}", "active": "2"], ["split": "file:///tmp/x/"],
                ["url": "file:///tmp/b/", "split": "file:///tmp/c/"],
            ], [],
        ]
        let read = SessionState(stored: old)
        #expect(read.windows.count == 1)
        let w = try #require(read.windows.first)
        // The unreadable second tab is left out; the active one is still the third.
        #expect(w.tabs.map(\.primary.url.lastPathComponent) == ["a", "b"] && w.activeTab == 1)
        #expect(w.tabs[1].secondary?.url.path == "/tmp/c" && !w.tabs[1].activeIsSecondary)
        #expect(w.frame == [10, 20, 800, 600] && w.panels.places && w.panels.information && !w.panels.folders)
        #expect(SessionState(stored: "nonsense").windows.isEmpty && SessionState(stored: nil).windows.isEmpty)
    }

    @Test func goneLocationsAreLeftOutAndNamed() {
        let gone: Set<String> = ["/Volumes/Ejected/Work", "/tmp/deleted"]
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let session = SessionState(windows: [
            WindowLayout(
                tabs: [
                    TabLayout(primary: pane("/tmp/a")), TabLayout(primary: pane("/Volumes/Ejected/Work")),
                    TabLayout(primary: pane("/tmp/b"), secondary: pane("/tmp/deleted"), activeIsSecondary: true, splitFraction: 0.3, linked: true),
                    TabLayout(primary: pane("sftp://offline.example/home/")),
                ], activeTab: 2, frame: [3000, 100, 900, 600]),
            WindowLayout(tabs: [TabLayout(primary: pane("/tmp/deleted"))], frame: [100, 100, 900, 600]),
        ])
        let (kept, missing) = session.available(exists: { !gone.contains($0.path) }, screens: [screen])
        // The ejected disk's tab closes, the deleted split side closes, the offline server stays (it says so itself).
        #expect(kept.windows.count == 1)
        let w = kept.windows[0]
        #expect(w.tabs.map(\.primary.url.lastPathComponent) == ["a", "b", "home"])
        #expect(w.tabs[1].secondary == nil && !w.tabs[1].activeIsSecondary && !w.tabs[1].linked)
        // The active tab is still the one that was active; a frame on a display that's gone isn't kept.
        #expect(w.activeTab == 1 && w.frame == nil)
        #expect(missing == ["Work", "deleted", "deleted"])
        #expect(SessionState.missingMessage(["Work"]) == "“Work” is no longer available, so it wasn't reopened.")
        #expect(SessionState.missingMessage(missing)?.hasPrefix("3 folders") == true && SessionState.missingMessage([]) == nil)
        #expect(SessionState.exists(URL(string: "ftp://example.com/")!) && !SessionState.exists(url("/nonexistent/\(UUID())")))
    }

    @Test func aWindowComesBackAsItWasBeforeItIsShown() async throws {
        let s = try Scratch()
        let big = try s.folder("Big"), left = try s.folder("Left"), right = try s.folder("Right")
        for i in 0..<300 { _ = try s.file("Big/file \(i).txt") }
        Settings.shared.homeURL = try s.folder("Home")
        var details = ViewStyleStore().style(for: big)
        details.mode = .details
        let layout = WindowLayout(
            tabs: [
                TabLayout(primary: PaneLayout(url: big, props: details, scroll: [0, 1200])),
                TabLayout(primary: PaneLayout(url: left), secondary: PaneLayout(url: right), activeIsSecondary: true, splitFraction: 0.3),
            ], activeTab: 1, panels: PanelLayout(places: false, information: true), frame: [300, 200, 900, 600])
        Settings.store.set(SessionState(windows: [layout]).stored, forKey: SessionState.key)
        let before = AppDelegate.shared.windows.count
        #expect(AppDelegate.shared.restoreSession())
        defer { AppDelegate.shared.windows.dropFirst(before).forEach { $0.window?.close() } }
        let wc = try #require(AppDelegate.shared.windows.last)
        #expect(AppDelegate.shared.windows.count == before + 1)
        // A restore is under way until its windows have settled: a launch that dies meanwhile doesn't try again.
        #expect(Settings.store.bool(forKey: AppDelegate.restoringKey))
        // Shown as it was, and only so: the frame, the split tab with its right side active, the panels.
        #expect(AppDelegate.shared.firstShown.last?.tabs.map(\.primary.url.lastPathComponent) == ["Big", "Left"])
        #expect(wc.window?.frame == NSRect(x: 300, y: 200, width: 900, height: 600))
        #expect(wc.current == 1 && wc.tab.activeIsSecondary && abs(wc.tab.splitShare - 0.3) < 0.001)
        #expect(wc.showInformation && !wc.showPlaces && !wc.showFolders)
        #expect(wc.view.url.path == right.path)
        // The tab in the background is in Details, scrolled where it was.
        wc.showTab(0)
        await expectEventually { wc.view.list.visibleRect.minY == 1200 }
        #expect(wc.view.model.props.mode == .details && wc.captureLayout().tabs[0].primary.scroll == [0, 1200])
    }

    @Test func aRestoreThatDiedIsNotTriedAgain() {
        Settings.store.set(SessionState(windows: [WindowLayout(tabs: [TabLayout(primary: pane("/tmp"))])]).stored, forKey: SessionState.key)
        Settings.store.set(true, forKey: AppDelegate.restoringKey)
        let before = AppDelegate.shared.windows.count
        #expect(!AppDelegate.shared.restoreSession())
        #expect(AppDelegate.shared.windows.count == before && !Settings.store.bool(forKey: AppDelegate.restoringKey))
    }

    @Test func changesAreSavedWithinMomentsWithoutQuitting() async throws {
        let s = try Scratch()
        Settings.store.removeObject(forKey: SessionState.key)
        AppDelegate.shared.newWindow(at: s.url)
        let wc = try #require(AppDelegate.shared.windows.last)
        defer { wc.window?.close() }
        wc.addTab(url: try s.folder("Second"))
        // A burst of changes saves once, never later than the delay after the first.
        for _ in 0..<5 { AppDelegate.shared.sessionChanged() }
        await expectEventually(timeout: AppDelegate.sessionSaveDelay + 3) {
            SessionState(stored: Settings.store.object(forKey: SessionState.key)).windows.last?.tabs.count == 2
        }
    }
}
