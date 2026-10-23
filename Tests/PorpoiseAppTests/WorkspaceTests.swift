import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Named workspaces and Quick Select on real windows (not shown): a window's layout goes into a workspace and comes
/// back the same in another window.
@MainActor @Suite(.serialized, .isolatedSettings) struct WorkspaceTests {
    init() { _ = NSApplication.shared }

    /// A, B, Many (60 files), Docs with a few kinds of files.
    private func tree() throws -> Scratch {
        let s = try Scratch()
        try s.folder("A")
        try s.folder("B")
        for i in 0..<60 { try s.file(String(format: "Many/file-%02d.txt", i), "x") }
        for name in ["Notes.txt", "Readme.md", "Budget.csv", "photo.JPG", "archive.tar.gz"] { try s.file("Docs/\(name)", "x") }
        try s.folder("Docs/Sub.txt")
        return s
    }

    private func loaded(_ wc: MainWindowController) async -> Bool {
        await eventually { wc.tabs.allSatisfy { t in t.containers.allSatisfy { $0.waitsToLoad || !$0.model.isLoading } } }
    }

    private func withoutFrame(_ l: WindowLayout) -> WindowLayout {
        var l = l
        l.frame = nil
        return l
    }

    @Test func aWorkspaceGivesAnotherWindowTheSameView() async throws {
        let s = try tree()
        let a = s.url.appendingPathComponent("A"), b = s.url.appendingPathComponent("B"), many = s.url.appendingPathComponent("Many")
        let wc = MainWindowController(urls: [many, a], split: [b, nil])
        #expect(await loaded(wc))
        let left = wc.tabs[0].primary, right = try #require(wc.tabs[0].secondary)
        var props = left.model.props
        props.mode = .details
        props.sortRole = .size
        props.sortOrder = .descending
        props.showHidden = true
        left.model.showProps(props)
        left.filterBar.isLocked = true
        left.filterBar.set(NameFilter(text: "file-0", mode: .plainText))
        left.filterBar.isHidden = false
        var compact = right.model.props
        compact.mode = .compact
        right.model.showProps(compact)
        wc.tabs[0].setSplitShare(0.35)
        wc.tabs[0].linkedRoots = (many, b)
        wc.tabs[1].customTitle = "Notes"
        wc.showFolders = true
        wc.showPlaces = false
        wc.rebuildPanels()
        wc.showTab(1)
        let layout = wc.captureLayout()
        #expect(layout.tabs.count == 2 && layout.activeTab == 1)
        #expect(layout.tabs[0].primary.props?.sortRole == .size && layout.tabs[0].primary.filter?.text == "file-0")
        #expect(layout.tabs[0].secondary?.props?.mode == .compact && layout.tabs[0].linked)
        #expect(abs((layout.tabs[0].splitFraction ?? 0) - 0.35) < 0.001 && layout.tabs[1].title == "Notes")
        #expect(layout.panels.folders && !layout.panels.places)

        // Through JSON, as a saved workspace is.
        let saved = try JSONDecoder().decode(WindowLayout.self, from: JSONEncoder().encode(layout))
        let other = MainWindowController(urls: [s.url])
        #expect(other.applyLayout(saved))
        #expect(await loaded(other))
        #expect(withoutFrame(other.captureLayout()) == withoutFrame(layout))
        #expect(other.tabs[0].primary.model.rows.count == 10, "the filter applies")
        #expect(other.current == 1 && other.tabs[0].linkedRoots?.right == b && other.tabs[0].containers.allSatisfy { $0.preservesMissingLocation })
    }

    @Test func columnsStartAtTheirRootAndOtherModesLeaveColumns() async throws {
        let s = try tree()
        let docs = s.url.appendingPathComponent("Docs"), sub = docs.appendingPathComponent("Sub.txt")
        var columns = ViewProperties()
        columns.mode = .columns
        var details = ViewProperties()
        details.mode = .details
        let layout = WindowLayout(tabs: [
            TabLayout(primary: PaneLayout(url: sub, columnRoot: docs, props: columns)),
            TabLayout(primary: PaneLayout(url: docs, props: details)),
        ])
        // The folders' own (common) style is Columns: the second tab must still show Details.
        let wc = MainWindowController(urls: [s.url])
        wc.view.setMode(.columns)
        #expect(wc.applyLayout(layout))
        #expect(await loaded(wc))
        #expect(wc.tabs[0].primary.url == sub && wc.tabs[0].primary.columnBrowser != nil)
        wc.showTab(1)
        #expect(wc.view.model.props.mode == .details)
        let back = wc.captureLayout()
        #expect(back.tabs[0].primary.columnRoot == docs && back.tabs[0].primary.url == sub && back.tabs[1].primary.props?.mode == .details)
    }

    @Test func aServerTabConnectsWhenShownAndKeepsItsPlace() async throws {
        let s = try tree()
        let server = try #require(URL(string: "sftp://nobody@127.0.0.1:1/srv/data"))
        let layout = WindowLayout(tabs: [
            TabLayout(primary: PaneLayout(url: s.url)),
            TabLayout(primary: PaneLayout(url: server, scroll: [0, 40]), secondary: PaneLayout(url: s.url.appendingPathComponent("A"))),
        ])
        let wc = MainWindowController(urls: [s.url])
        #expect(wc.applyLayout(layout))
        let tab = wc.tabs[1]
        #expect(tab.containers.allSatisfy { $0.waitsToLoad }, "a hidden tab with a server pane lists nothing yet")
        // Saved again before it was ever shown: the same place, scroll position included.
        let again = wc.captureLayout()
        #expect(again.locations == layout.locations && again.tabs[1].primary.scroll == [0, 40])
        wc.showTab(1)
        #expect(!tab.primary.waitsToLoad && !(tab.secondary?.waitsToLoad ?? true))
        #expect(await eventually(10) { tab.primary.model.loadError != nil })
        #expect(wc.tabs[1].primary.url == server)
    }

    @Test func aLayoutThatCantBeAppliedLeavesTheWindowAsItWas() throws {
        let s = try tree()
        let wc = MainWindowController(urls: [s.url, s.url.appendingPathComponent("A")])
        var newer = WindowLayout(tabs: [TabLayout(primary: PaneLayout(url: s.url))])
        newer.version = WindowLayout.currentVersion + 1
        #expect(!wc.applyLayout(newer))
        #expect(!wc.applyLayout(WindowLayout(tabs: [])))
        #expect(wc.tabs.count == 2)
    }

    @Test func layoutsHoldNoPasswords() throws {
        let s = try tree()
        let wc = MainWindowController(urls: [s.url])
        let server = try #require(URL(string: "ftp://me:secret@127.0.0.1:1/x"))
        let layout = WindowLayout(tabs: [TabLayout(primary: PaneLayout(url: server))])
        wc.applyLayout(layout)
        let json = String(decoding: try JSONEncoder().encode(wc.captureLayout()), as: UTF8.self)
        #expect(!json.contains("secret"))
    }

    @Test func savingOpeningAndDeletingWorkspaces() async throws {
        let s = try tree()
        let wc = MainWindowController(urls: [s.url.appendingPathComponent("A"), s.url.appendingPathComponent("B")])
        #expect(wc.workspacesMenu().items.first?.title == "No Saved Workspaces")
        let first = try #require(Settings.shared.saveWorkspace(named: "  Two\nTabs ", layout: wc.captureLayout()))
        #expect(first.name == "Two Tabs")
        #expect(Settings.shared.saveWorkspace(named: " ", layout: wc.captureLayout()) == nil)
        // The same name in another case replaces it, keeping its identity.
        wc.closeTab(1)
        let replaced = try #require(Settings.shared.saveWorkspace(named: "two tabs", layout: wc.captureLayout()))
        #expect(replaced.id == first.id && Settings.shared.workspaces.count == 1 && Settings.shared.workspaces[0].layout.tabs.count == 1)
        Settings.shared.saveWorkspace(named: "Alpha", layout: WindowLayout(tabs: [TabLayout(primary: PaneLayout(url: s.url))]))
        #expect(Settings.shared.workspaces.map(\.name) == ["Alpha", "two tabs"])
        #expect(!Settings.shared.renameWorkspace(id: first.id, to: "ALPHA") && !Settings.shared.renameWorkspace(id: first.id, to: ""))
        #expect(!Settings.shared.renameWorkspace(id: UUID(), to: "Zed"))
        #expect(Settings.shared.renameWorkspace(id: first.id, to: "Zed") && Settings.shared.workspaces.map(\.name) == ["Alpha", "Zed"])

        let menu = wc.workspacesMenu()
        let open = try #require(menu.items.first { $0.title == "Alpha" && !$0.isAlternate })
        #expect(menu.items.contains { $0.isAlternate && $0.title == "Alpha in New Window" })
        #expect(menu.items.last?.submenu?.items.map(\.title) == ["Alpha", "Zed"])
        let before = wc.tabs.count
        wc.openWorkspace(open)
        #expect(wc.tabs.count == 1 && wc.view.url == s.url)
        #expect(wc.closedTabs.count >= before, "the replaced tabs can be reopened")
        wc.openWorkspace(nil)
        #expect(wc.view.url == s.url)

        Settings.shared.deleteWorkspace(id: first.id)
        #expect(Settings.shared.workspaces.map(\.name) == ["Alpha"])
    }

    @Test func aWorkspaceSavedByANewerVersionIsSkippedNotLost() throws {
        let s = try tree()
        Settings.shared.saveWorkspace(named: "Kept", layout: WindowLayout(tabs: [TabLayout(primary: PaneLayout(url: s.url))]))
        let stored = try #require(Settings.store.data(forKey: "workspaces"))
        var raw = try #require(try JSONSerialization.jsonObject(with: stored) as? [Any])
        raw.append(["name": "Future", "layout": ["hologram": true]])
        Settings.store.set(try JSONSerialization.data(withJSONObject: raw), forKey: "workspaces")
        #expect(Settings.shared.workspaces.map(\.name) == ["Kept"])
    }

    @Test func saveSheetSaysWhenItReplaces() throws {
        let s = try tree()
        Settings.shared.saveWorkspace(named: "Photos", layout: WindowLayout(tabs: [TabLayout(primary: PaneLayout(url: s.url))]))
        let two = WindowLayout(tabs: [TabLayout(primary: PaneLayout(url: s.url)), TabLayout(primary: PaneLayout(url: s.url))])
        let sheet = WorkspaceSaveSheet(layout: two)
        sheet.build()
        #expect(sheet.status == ("Save", false, ""))
        sheet.field.stringValue = "photos"
        sheet.validate()
        #expect(sheet.status == ("Replace", true, "Replaces the saved workspace “Photos”."))
        sheet.field.stringValue = "Work"
        sheet.validate()
        #expect(sheet.status == ("Save", true, ""))
        sheet.finish(true)
        #expect(Settings.shared.workspaces.map(\.name) == ["Photos", "Work"] && Settings.shared.workspaces[1].layout == two)
        sheet.finish(false)
        #expect(Settings.shared.workspaces.count == 2)
    }

    @Test func quickSelectChangesTheActiveViewsSelection() async throws {
        let s = try tree()
        let docs = s.url.appendingPathComponent("Docs")
        let wc = MainWindowController(urls: [docs])
        #expect(await eventually { !wc.view.model.isLoading && wc.view.model.rows.count == 6 })
        func selected() -> [String] { wc.view.model.selectedItems.map(\.name).sorted() }
        #expect(wc.applyQuickSelect(QuickSelect(.fileExtension, "txt"), action: .select) == 1)
        #expect(selected() == ["Notes.txt"], "a folder named like a file isn't picked by extension")
        wc.applyQuickSelect(QuickSelect(.name, "*.txt"), action: .add)
        #expect(selected() == ["Notes.txt", "Sub.txt"])
        wc.applyQuickSelect(QuickSelect(.fileExtension, "jpg gz"), action: .add)
        #expect(selected() == ["Notes.txt", "Sub.txt", "archive.tar.gz", "photo.JPG"])
        wc.applyQuickSelect(QuickSelect(.name, "*.txt"), action: .remove)
        #expect(selected() == ["archive.tar.gz", "photo.JPG"])
        #expect(wc.applyQuickSelect(QuickSelect(.name, "["), action: .select) == nil)
        #expect(selected() == ["archive.tar.gz", "photo.JPG"], "an invalid pattern changes nothing")
        #expect(wc.view.model.currentURL?.lastPathComponent == "archive.tar.gz")
    }

    @Test func quickSelectSheetCountsAsYouTypeAndRemembers() async throws {
        let s = try tree()
        let wc = MainWindowController(urls: [s.url.appendingPathComponent("Docs")])
        #expect(await eventually { !wc.view.model.isLoading && wc.view.model.rows.count == 6 })
        let sheet = QuickSelectSheet(owner: wc)
        sheet.build(action: .select)
        #expect(sheet.status.text == "" && !sheet.status.enabled && sheet.defaultButtonTitle == "Select")
        sheet.fill(QuickSelect(.fileExtension, "md, csv"), action: .add)
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(sheet.status == ("2 items of 6 match.", true))
        #expect(sheet.field.objectValues.compactMap { $0 as? String }.contains("md"), "the folder's extensions are offered")
        sheet.fill(QuickSelect(.name, "["), action: .remove)
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(sheet.status == ("Not a valid pattern.", false) && sheet.defaultButtonTitle == "Deselect")
        sheet.fill(QuickSelect(.name, "zzz"), action: .select)
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(sheet.status == ("No items match.", true))
        sheet.fill(QuickSelect(.tag, "Red"), action: .select)
        #expect(sheet.query.criterion == .tag)
        sheet.fill(QuickSelect(.fileExtension, "md, csv"), action: .add)
        sheet.finish(true)
        #expect(wc.view.model.selectedItems.map(\.name).sorted() == ["Budget.csv", "Readme.md"])
        #expect(QuickSelectSheet.last == QuickSelect(.fileExtension, "md, csv"))
        // The next one starts from it.
        let again = QuickSelectSheet(owner: wc)
        again.build(action: .select)
        #expect(again.query == QuickSelect(.fileExtension, "md, csv"))
        again.finish(false)
    }
}
