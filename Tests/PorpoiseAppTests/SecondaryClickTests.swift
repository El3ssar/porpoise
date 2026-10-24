import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@Suite(.serialized, .isolatedSettings) @MainActor struct SecondaryClickTests {
    init() { _ = NSApplication.shared }

    private final class ListRecorder: ItemListViewDelegate {
        var opened = 0
        var targets: [URL?] = []
        var returnsNil = false
        func itemList(_ view: ItemListView, open items: [FileItem], inNewTab: Bool) { opened += 1 }
        func itemList(_ view: ItemListView, menuFor item: FileItem?) -> NSMenu? {
            targets.append(item?.url)
            if returnsNil { return nil }
            let menu = NSMenu()
            menu.addItem(withTitle: "Get Info", action: nil, keyEquivalent: "")
            return menu
        }
        func itemList(_ view: ItemListView, drop urls: [URL], onto folder: URL, operation: NSDragOperation, event: NSEvent?) {}
        func itemList(_ view: ItemListView, rename item: FileItem, to name: String) {}
        func itemListDidBecomeActive(_ view: ItemListView) {}
        func itemList(_ view: ItemListView, hovered item: FileItem?) {}
        func itemListBackgroundDoubleClicked(_ view: ItemListView) { opened += 1 }
        func itemList(_ view: ItemListView, middleClicked item: FileItem) {}
        func itemListQuickLook(_ view: ItemListView) {}
    }

    private final class AppsRecorder: AppsViewHost {
        var opened = 0
        var targets: [URL?] = []
        func appsViewDidBecomeActive(_ v: AppsView) {}
        func appsView(_ v: AppsView, open items: [FileItem]) { opened += 1 }
        func appsView(_ v: AppsView, menuFor item: FileItem?) -> NSMenu? {
            targets.append(item?.url)
            return NSMenu(title: "Applications")
        }
        func appsViewQuickLook(_ v: AppsView) {}
        func appsView(_ v: AppsView, hovered item: FileItem?) {}
    }

    private final class PlacesRecorder: PlacesPanelDelegate {
        var opened = 0
        func places(_ p: PlacesPanel, open url: URL, newTab: Bool, splitView: Bool) { opened += 1 }
        func places(_ p: PlacesPanel, drop urls: [URL], onto url: URL, operation: NSDragOperation) {}
        func places(_ p: PlacesPanel, emptyTrash: Void) {}
        func places(_ p: PlacesPanel, properties url: URL) {}
        func placesWantsViewFocus(_ p: PlacesPanel) {}
    }

    private func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        return window
    }

    /// AppKit delivers a mouse/trackpad secondary click as rightMouseDown; control-click remains leftMouseDown.
    private func click(_ view: NSView, at point: CGPoint, control: Bool, count: Int = 1) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: control ? [.control] : [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        if control {
            view.mouseDown(with: event(.leftMouseDown))
            view.mouseUp(with: event(.leftMouseUp))
        } else {
            view.rightMouseDown(with: event(.rightMouseDown))
            view.rightMouseUp(with: event(.rightMouseUp))
        }
    }

    @Test func controlDoubleClickIsNotAnOpen() async throws {
        let scratch = try Scratch()
        try scratch.file("a.txt")
        let model = try await DirectoryModel.loaded(scratch.url)
        let list = ItemListView(model: model), recorder = ListRecorder()
        list.delegate = recorder
        let window = window(list)
        defer { window.close(); SecondaryClick.presentForTesting = nil }
        list.computeLayout()
        var presented = 0
        SecondaryClick.presentForTesting = { _, _, _ in presented += 1 }
        click(list, at: CGPoint(x: list.frames[0].midX, y: list.frames[0].midY), control: true, count: 2)
        #expect(recorder.opened == 0)
        #expect(presented == 1)
    }

    @Test func aMissingMenuNeverFallsThroughToOpening() async throws {
        let scratch = try Scratch()
        try scratch.file("a.txt")
        let model = try await DirectoryModel.loaded(scratch.url)
        let list = ItemListView(model: model), recorder = ListRecorder()
        recorder.returnsNil = true
        list.delegate = recorder
        let window = window(list)
        defer { window.close() }
        list.computeLayout()
        for control in [false, true] {
            click(list, at: CGPoint(x: list.frames[0].midX, y: list.frames[0].midY), control: control, count: 2)
        }
        #expect(recorder.opened == 0 && recorder.targets.count == 2)
    }

    @Test(arguments: [ViewMode.icons, .details, .compact, .columns])
    func fileViewsPresentMenusWithoutOpeningOrCollapsingSelection(mode: ViewMode) async throws {
        let scratch = try Scratch()
        try scratch.file("a.txt"); try scratch.file("b.txt"); try scratch.file("tree/child.txt")
        let model = try await DirectoryModel.loaded(scratch.url)
        model.props.mode = mode
        if mode == .details {
            model.toggleExpanded(scratch.path("tree"))
            try #require(await eventually { model.index(of: scratch.path("tree/child.txt")) != nil })
        }
        let list = ItemListView(model: model), recorder = ListRecorder()
        list.delegate = recorder
        let window = window(list)
        defer { window.close(); SecondaryClick.presentForTesting = nil }
        list.computeLayout()
        let url = mode == .details ? scratch.path("tree/child.txt") : scratch.path("b.txt")
        let i = try #require(model.index(of: url))
        let point = CGPoint(x: list.frames[i].midX, y: list.frames[i].midY)
        var presented = 0
        SecondaryClick.presentForTesting = { menu, _, view in
            #expect(view === list && menu.items.first?.title == "Get Info")
            #expect(model.selection.contains(url))
            presented += 1
        }
        for control in [false, true] {
            for count in [1, 2] {
                for selected in [Set([scratch.path("a.txt")]), Set([scratch.path("a.txt"), url])] {
                    model.selection = selected
                    let expected = selected.contains(url) ? selected : [url]
                    let before = presented
                    click(list, at: point, control: control, count: count)
                    #expect(presented == before + 1)
                    #expect(recorder.targets.last == url && recorder.opened == 0)
                    #expect(model.selection == expected && model.currentURL == url)
                    #expect(list.mouseDownIndex == nil && list.rubberStart == nil)
                }
            }
        }
    }

    @Test func searchResultsUseTheSameSecondaryClickPath() async throws {
        let scratch = try Scratch()
        try scratch.file("nested/result.txt")
        let model = try await DirectoryModel.loaded(scratch.url)
        model.searchResults = [FileItem(url: scratch.path("nested/result.txt"), name: "result.txt", isDirectory: false)]
        model.showSearchView()
        let list = ItemListView(model: model), recorder = ListRecorder()
        list.delegate = recorder
        let window = window(list)
        defer { window.close(); SecondaryClick.presentForTesting = nil }
        list.computeLayout()
        var presented = 0
        SecondaryClick.presentForTesting = { _, _, _ in presented += 1 }
        for control in [false, true] {
            click(list, at: CGPoint(x: list.frames[0].midX, y: list.frames[0].midY), control: control, count: 2)
        }
        #expect(presented == 2 && recorder.opened == 0)
        #expect(recorder.targets.compactMap { $0 } == [scratch.path("nested/result.txt"), scratch.path("nested/result.txt")])
    }

    @Test func applicationsPresentMenusWithoutLaunchingOrCollapsingSelection() async throws {
        let scratch = try Scratch()
        try scratch.folder("A.app"); try scratch.folder("B.app")
        let model = try await DirectoryModel.loaded(scratch.url)
        let apps = AppsView(model: model), recorder = AppsRecorder()
        apps.host = recorder
        let window = window(apps)
        defer { window.close(); SecondaryClick.presentForTesting = nil }
        apps.grid.updateLayout(width: 800)
        let regions = try #require(apps.grid.accessibilityChildren() as? [AccessibleRegion])
        let r = try #require(regions.last).accessibilityFrameInParentSpace()
        let url = try #require(model.rows.last?.item.url)
        var presented = 0
        SecondaryClick.presentForTesting = { _, _, _ in
            #expect(model.selection.contains(url))
            presented += 1
        }
        for control in [false, true] {
            for count in [1, 2] {
                for selected in [Set([scratch.path("A.app")]), Set(model.rows.map(\.item.url))] {
                    model.selection = selected
                    click(apps.grid, at: CGPoint(x: r.midX, y: r.midY), control: control, count: count)
                    #expect(model.selection == (selected.contains(url) ? selected : [url]))
                    #expect(recorder.targets.last == url && recorder.opened == 0)
                }
            }
        }
        #expect(presented == 8)
    }

    @Test func placesPresentMenusWithoutNavigating() throws {
        let panel = PlacesPanel(frame: .zero), recorder = PlacesRecorder()
        panel.delegate = recorder
        let window = window(panel)
        defer { window.close(); SecondaryClick.presentForTesting = nil }
        let originalURL = panel.currentURL
        let folder = try #require(panel.entryIndices.first { panel.entry(at: $0)?.url.isFileURL == true })
        let airDrop = try #require(panel.entryIndices.first { panel.entry(at: $0)?.url == PlacesModel.airDropURL })
        for i in [folder, airDrop] {
            let entry = try #require(panel.entry(at: i))
            let rect = panel.rect(of: i)
            let title = i == airDrop ? "Open AirDrop" : "Open in New Tab"
            var presented = 0
            SecondaryClick.presentForTesting = { menu, _, _ in
                #expect(menu.items.contains { $0.title == title })
                #expect(panel.isCurrent(entry))
                presented += 1
            }
            for control in [false, true] {
                for count in [1, 2] { click(panel, at: CGPoint(x: 70, y: rect.midY), control: control, count: count) }
            }
            #expect(presented == 4 && recorder.opened == 0)
            #expect(panel.currentURL == originalURL && panel.contextMenuURL == nil)
        }
    }

    @Test func foldersPresentMenusForTheClickedRowWithoutNavigating() async throws {
        let scratch = try Scratch()
        try scratch.folder("a"); try scratch.folder("b")
        Settings.shared.homeURL = scratch.url
        Settings.shared.foldersLimitToHome = true
        let panel = FoldersPanel(frame: .zero)
        var opened = 0
        panel.onNavigate = { _, _ in opened += 1 }
        let window = window(panel)
        defer { window.close(); SecondaryClick.presentForTesting = nil }
        let outline = try #require((panel.subviews.first as? NSScrollView)?.documentView as? NSOutlineView)
        panel.currentURL = scratch.path("a")
        try #require(await eventually { outline.numberOfRows >= 2 })
        let target = try #require((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? FoldersPanel.Node)?.url == scratch.path("b") })
        var presented = 0
        SecondaryClick.presentForTesting = { menu, _, _ in
            menu.delegate?.menuNeedsUpdate?(menu)
            #expect(menu.items.first?.representedObject as? URL == scratch.path("b"))
            #expect(outline.selectedRow == target)
            presented += 1
        }
        let rect = outline.rect(ofRow: target)
        for control in [false, true] {
            for count in [1, 2] {
                click(outline, at: CGPoint(x: 100, y: rect.midY), control: control, count: count)
            }
        }
        #expect(presented == 4 && opened == 0)
        #expect(panel.currentURL == scratch.path("a"))
    }
    private final class ContainerRecorder: ViewContainerDelegate {
        let controller: MainWindowController
        var opened = 0
        var menus = 0
        var suppressPresentation = false
        init(_ controller: MainWindowController) { self.controller = controller }
        func containerDidBecomeActive(_ c: ViewContainer) {}
        func containerDidChangeURL(_ c: ViewContainer) {}
        func containerSelectionChanged(_ c: ViewContainer) {}
        func container(_ c: ViewContainer, open items: [FileItem], inNewTab: Bool) { opened += 1 }
        func container(_ c: ViewContainer, menuFor item: FileItem?) -> NSMenu? {
            menus += 1
            let menu = controller.contextMenu(for: item, in: c)
            return suppressPresentation ? nil : menu
        }
        func container(_ c: ViewContainer, drop urls: [URL], onto folder: URL, operation: NSDragOperation) {}
        func container(_ c: ViewContainer, rename item: FileItem, to name: String) {}
        func container(_ c: ViewContainer, middleClicked item: FileItem) {}
        func containerQuickLook(_ c: ViewContainer) {}
        func containerSearchVisibilityChanged(_ c: ViewContainer) {}
    }

    private final class Provider: RemoteProvider {
        func list(_ folder: URL) throws -> [FileItem] {
            [
                FileItem(url: folder.appendingPathComponent("note.txt"), name: "note.txt", isDirectory: false),
                FileItem(url: folder.appendingPathComponent("folder"), name: "folder", isDirectory: true),
            ]
        }
        func rootTitle(_ url: URL) -> String { "Context click fixture" }
        func download(_ remote: URL, into localFolder: URL) throws -> URL { throw CocoaError(.featureUnsupported) }
        func upload(_ local: URL, into remoteFolder: URL) throws { throw CocoaError(.featureUnsupported) }
        func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
        func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
        func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
        func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
        func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    }

    @Test(arguments: ["gdrive", "sftp"])
    func fakeProviderMenusNeverFallThroughToOpen(scheme: String) async throws {
        try await exerciseProvider(scheme, nativeProbe: false)
    }

    /// Can also run against the original handler: construct the real menu, then return nil to avoid modal tracking.
    @Test(arguments: ["gdrive", "sftp"])
    func nativeProviderRightClicksReachTheMenuBuilder(scheme: String) async throws {
        try await exerciseProvider(scheme, nativeProbe: true)
    }

    private func exerciseProvider(_ scheme: String, nativeProbe: Bool) async throws {
        let account = UUID().uuidString.lowercased()
        let root = try #require(URL(string: "\(scheme)://\(account)/my-drive/"))
        let backend = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = DemoCloudBackend(accounts: [
            CloudAccount(id: account, email: "fixture@example.invalid", displayName: "Fixture")
        ])
        RemoteFS.use(Provider(), for: root)
        ColumnBrowserView.mouseIsDown = { false }
        defer {
            RemoteFS.use(nil, for: root)
            CloudAccounts.shared.backend = backend
            SecondaryClick.presentForTesting = nil
        }
        let tab = PorpoiseTab(url: root), controller = MainWindowController(window: nil)
        controller.tabs = [tab]
        let pane = tab.primary, recorder = ContainerRecorder(controller)
        recorder.suppressPresentation = nativeProbe
        pane.delegate = recorder
        let window = window(pane)
        defer { window.close() }
        try #require(await eventually { !pane.model.isLoading && pane.model.rows.count == 2 })
        var presented = 0
        SecondaryClick.presentForTesting = { menu, _, _ in
            #expect(!menu.items.isEmpty)
            #expect(menu.items.contains { $0.title == "Get Info" })
            presented += 1
        }
        let target = root.appendingPathComponent("note.txt")
        for mode in [ViewMode.icons, .details, .compact, .columns] {
            pane.setMode(mode)
            pane.layoutSubtreeIfNeeded()
            pane.list.computeLayout()
            let i = try #require(pane.model.index(of: target))
            let point = CGPoint(x: pane.list.frames[i].midX, y: pane.list.frames[i].midY)
            // A primary click followed by a secondary click carrying clickCount 2 must still only show the menu.
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: pane.list.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            pane.list.mouseDown(with: down)
            for control in nativeProbe ? [false] : [false, true] {
                click(pane.list, at: point, control: control, count: 2)
                #expect(pane.model.selection == [target] && pane.url == root)
            }
        }
        #expect(presented == (nativeProbe ? 0 : 8) && recorder.menus == (nativeProbe ? 4 : 8) && recorder.opened == 0)
    }

    @Test func aSecondaryClickInAnotherColumnFocusesItsMenuWithoutOpening() async throws {
        let scratch = try Scratch()
        try scratch.file("folder/note.txt")
        ColumnBrowserView.mouseIsDown = { false }
        let tab = PorpoiseTab(url: scratch.url), controller = MainWindowController(window: nil)
        controller.tabs = [tab]
        let pane = tab.primary, recorder = ContainerRecorder(controller)
        pane.delegate = recorder
        let window = window(pane)
        defer { window.close(); SecondaryClick.presentForTesting = nil }
        try #require(await eventually { !pane.model.isLoading && !pane.model.rows.isEmpty })
        pane.setMode(.columns)
        var presented = 0
        SecondaryClick.presentForTesting = { menu, _, _ in
            #expect(!menu.items.isEmpty)
            presented += 1
        }
        for control in [false, true] {
            pane.setURL(scratch.url)
            try #require(await eventually { pane.model.index(of: scratch.path("folder")) != nil })
            pane.list.select(scratch.path("folder"))
            let next = try #require(pane.columnBrowser?.after)
            try #require(await eventually { next.model.index(of: scratch.path("folder/note.txt")) != nil })
            next.list.computeLayout()
            let i = try #require(next.model.index(of: scratch.path("folder/note.txt")))
            click(next.list, at: CGPoint(x: next.list.frames[i].midX, y: next.list.frames[i].midY), control: control, count: 2)
            #expect(pane.url.path == scratch.path("folder").path)
            #expect(pane.model.selection == [scratch.path("folder/note.txt")])
        }
        #expect(presented == 2 && recorder.opened == 0 && recorder.menus == 2)
    }
}
