import AVFoundation
import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Minor findings in the views, panels and dialogs (W-243, from the W-235 audit's appendices): each one pinned.
@Suite(.serialized, .isolatedSettings) @MainActor struct ViewMinorsTests {
    init() { _ = NSApplication.shared }

    /// #14: only the settings folder previews depend on rebuild them; an unrelated one leaves them alone.
    @Test func onlyPreviewSettingsResetFolderPreviews() {
        let thumbnails = Thumbnails()
        let start = thumbnails.folderGeneration
        for key in ["placesIconSize", "appLibraryIconSize", "verifyCopies", "terminalFollowDirectory"] {
            NotificationCenter.default.post(name: Settings.changed, object: key)
        }
        #expect(thumbnails.folderGeneration == start)
        NotificationCenter.default.post(name: Settings.changed, object: "pvFolders")
        #expect(thumbnails.folderGeneration == start + 1)
        NotificationCenter.default.post(name: Settings.changed, object: nil)  // several at once
        #expect(thumbnails.folderGeneration == start + 2)
    }

    /// #12: the cloud folder's second look, 0.4 s on, isn't shown over the local folder the pane went to meanwhile.
    @Test func aCloudRetryDoesNotLandOnTheNextFolder() async throws {
        let account = UUID().uuidString.lowercased()
        let root = try #require(URL(string: "gdrive://\(account)/my-drive/"))
        let backend = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = DemoCloudBackend(accounts: [
            CloudAccount(id: account, email: "fixture@example.invalid", displayName: "Fixture")
        ])
        RemoteFS.use(FailingProvider(), for: root)
        let s = try Scratch("cloud-retry")
        let locked = try s.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            RemoteFS.use(nil, for: root)
            CloudAccounts.shared.backend = backend
        }
        let pane = ViewContainer(url: root)
        try #require(await eventually { !pane.model.isLoading && pane.model.loadError != nil })
        pane.setURL(locked)
        try #require(await eventually { pane.model.location.path == locked.path && !pane.model.isLoading && pane.model.loadError != nil })
        try await Task.sleep(for: .milliseconds(700))
        #expect(!pane.messageBar.text.contains("isn’t connected"))
    }

    private func text(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { text(in: $0) }
    }

    /// #7: a file that changes while it stays selected (a download growing) shows its new size once it's listed again.
    @Test func theInformationPanelFollowsAChangedFile() async throws {
        let s = try Scratch("info-follows")
        let file = try s.file("grow.bin", String(repeating: "x", count: 10))
        let pane = ViewContainer(url: s.url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        defer { window.close() }
        try #require(await eventually { !pane.model.isLoading && pane.model.rows.count == 1 })
        let panel = InformationPanel(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        pane.list.select(file)
        panel.show(hovered: nil, container: pane)
        try #require(await eventually { self.text(in: panel).contains("10 B") })
        try Data(repeating: 1, count: 4096).write(to: file)
        pane.reload()
        #expect(await eventually { self.text(in: panel).contains("4 KB") })
        // And it stays: a read of the item begun before it changed doesn't land afterwards.
        try await Task.sleep(for: .milliseconds(300))
        #expect(self.text(in: panel).contains("4 KB"))
    }

    /// #10: a URL that isn't shown is looked up once per listing, however many thumbnails ask about it.
    @Test func missedLookupsAreRemembered() async throws {
        let s = try Scratch("lookups")
        try s.file("a.txt", "a")
        let model = DirectoryModel(location: s.url, prefetchFolders: false)
        model.reload()
        try #require(await eventually { !model.isLoading && model.rows.count == 1 })
        let elsewhere = URL(fileURLWithPath: "/tmp/porpoise-not-here-\(UUID().uuidString).png")
        #expect(model.index(of: elsewhere) == nil)
        #expect(model.missedLookups == [elsewhere])
        #expect(model.index(of: elsewhere) == nil)
        #expect(model.index(of: s.path("a.txt")) == 0)
        // A new listing forgets them: the file may be shown now.
        try s.file("b.txt", "b")
        model.reload()
        try #require(await eventually { !model.isLoading && model.rows.count == 2 })
        #expect(model.missedLookups.isEmpty)
    }

    /// #19: type-ahead ignores case and accents.
    @Test func typeAheadIgnoresAccents() {
        #expect(ItemListView.name("École", startsWith: "e"))
        #expect(ItemListView.name("école.txt", startsWith: "ECO"))
        #expect(ItemListView.name("Résumé", startsWith: "resu"))
        #expect(!ItemListView.name("Notes", startsWith: "otes"))
        #expect(!ItemListView.name("ab", startsWith: "abc"))
    }

    /// #21: light ↔ dark renders the app library's tiles again (apps whose icons follow the appearance).
    @Test func appTilesFollowTheAppearance() throws {
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        model.searchResults = (0..<4).map { i in
            FileItem(url: URL(fileURLWithPath: "/Applications/Fixture-\(i).app"), name: "Fixture-\(i).app", isDirectory: true, isApplication: true)
        }
        let grid = AppsGridView(model: model)
        grid.appearance = NSAppearance(named: .aqua)
        grid.updateLayout(width: 800)
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for _ in 0..<10 { grid.draw(CGRect(x: 0, y: 0, width: 800, height: 600)) }
        NSGraphicsContext.restoreGraphicsState()
        try #require(grid.retainedTileBytes > 0)
        grid.appearance = NSAppearance(named: .darkAqua)
        #expect(grid.retainedTileBytes == 0)
    }

    /// #20: a drop on Places goes where it's released, even after the rows moved under the held drag.
    @Test func aPlacesDropUsesTheRowsAsTheyAreNow() throws {
        let s = try Scratch("places-drop")
        let a = try s.folder("A"), b = try s.folder("B"), x = try s.folder("X")
        let file = try s.file("dragged.txt", "x")
        let panel = PlacesPanel(frame: CGRect(x: 0, y: 0, width: 240, height: 500))
        let drops = PlaceDrops()
        panel.delegate = drops
        func entry(_ u: URL) -> PlaceEntry { PlaceEntry(title: u.lastPathComponent, url: u, icon: "folder", section: .places) }
        panel.rows = [.init(kind: .entry(entry(a)), y: 0, height: 28), .init(kind: .entry(entry(b)), y: 28, height: 28)]
        let drag = FakeDrag([file], mask: [.copy, .move], at: panel.convert(CGPoint(x: 80, y: 42), to: nil))
        #expect(panel.draggingUpdated(drag) != [])
        #expect(panel.dropIndex == 1)  // B
        // A row appears above while the drag is held: the pointer is now over B at index 2, A sits at index 1.
        panel.rows = [
            .init(kind: .entry(entry(x)), y: 0, height: 10), .init(kind: .entry(entry(a)), y: 10, height: 28),
            .init(kind: .entry(entry(b)), y: 38, height: 28),
        ]
        #expect(panel.performDragOperation(drag))
        #expect(drops.dropped.map(\.folder) == [b])
    }

    /// #17: column dividers, resize grips, tag outlines and the Shelf's text take the theme's colours (a palette theme
    /// such as Breeze or High Contrast), never the system's greys.
    @Test func themedPanesUseThemeColours() throws {
        for file in [
            "Sources/Porpoise/Views/ColumnResizeHandle.swift", "Sources/Porpoise/Panels/ShelfPanel.swift",
            "Sources/Porpoise/Views/FinderTags+AppKit.swift",
        ] {
            let text = try String(contentsOf: TestPaths.repo.appendingPathComponent(file), encoding: .utf8)
            for grey in ["separatorColor", "secondaryLabelColor", "tertiaryLabelColor"] { #expect(!text.contains(grey), "\(file): \(grey)") }
        }
        let columns = try String(contentsOf: TestPaths.repo.appendingPathComponent("Sources/Porpoise/Views/ColumnBrowserView.swift"), encoding: .utf8)
        #expect(!columns.contains("NSColor.separatorColor"))
    }

    private final class PlaceDrops: PlacesPanelDelegate {
        var dropped: [(urls: [URL], folder: URL)] = []
        func places(_ p: PlacesPanel, open url: URL, newTab: Bool, splitView: Bool) {}
        func places(_ p: PlacesPanel, drop urls: [URL], onto url: URL, operation: NSDragOperation) { dropped.append((urls, url)) }
        func places(_ p: PlacesPanel, emptyTrash: Void) {}
        func places(_ p: PlacesPanel, properties url: URL) {}
        func placesWantsViewFocus(_ p: PlacesPanel) {}
    }

    private final class FailingProvider: RemoteProvider {
        func list(_ folder: URL) throws -> [FileItem] { throw CocoaError(.fileReadNoPermission) }
        func rootTitle(_ url: URL) -> String { "Failing fixture" }
        func download(_ remote: URL, into localFolder: URL) throws -> URL { throw CocoaError(.featureUnsupported) }
        func upload(_ local: URL, into remoteFolder: URL) throws { throw CocoaError(.featureUnsupported) }
        func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
        func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
        func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
        func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
        func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    }

    /// #8: in Column view on a server, a column other than the focused one shows what an operation changed in it.
    @Test func otherColumnsOnAServerFollowChanges() async throws {
        let root = try #require(URL(string: "sftp://columns-\(UUID().uuidString.prefix(6).lowercased()).invalid/"))
        let server = ChangingServer()
        RemoteFS.use(server, for: root)
        defer { RemoteFS.use(nil, for: root) }
        let pane = ViewContainer(url: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        defer { window.close() }
        try #require(await eventually { !pane.model.isLoading && pane.model.rows.count == 2 })
        pane.setMode(.columns)
        pane.setURL(root.appendingPathComponent("a/"))
        let browser = try #require(pane.columnBrowser)
        try #require(await eventually { browser.before.first.map { !$0.model.isLoading && $0.model.rows.count == 2 } == true })
        server.extra = ["new.txt"]
        FileOperationsController.notifyChanged([root.appendingPathComponent("new.txt")])
        #expect(await eventually { browser.before.first?.model.rows.contains { $0.item.name == "new.txt" } == true })
    }

    private final class ChangingServer: RemoteProvider, @unchecked Sendable {
        var extra: [String] = []
        func list(_ folder: URL) throws -> [FileItem] {
            if folder.lastPathComponent == "a" {
                return [FileItem(url: folder.appendingPathComponent("inner.txt"), name: "inner.txt", isDirectory: false)]
            }
            return [
                FileItem(url: folder.appendingPathComponent("a/"), name: "a", isDirectory: true),
                FileItem(url: folder.appendingPathComponent("b.txt"), name: "b.txt", isDirectory: false),
            ] + extra.map { FileItem(url: folder.appendingPathComponent($0), name: $0, isDirectory: false) }
        }
        func rootTitle(_ url: URL) -> String { "Changing" }
        func download(_ remote: URL, into localFolder: URL) throws -> URL { throw CocoaError(.featureUnsupported) }
        func upload(_ local: URL, into remoteFolder: URL) throws { throw CocoaError(.featureUnsupported) }
        func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
        func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
        func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
        func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
        func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    }

    /// #9: the Folders panel shows a folder made in an open folder by another app, and stops showing one deleted.
    @Test(.timeLimit(.minutes(3))) func theFoldersPanelFollowsTheDisk() async throws {
        let s = try Scratch("folders-follow")
        try s.folder("Here/Old")
        let here = s.path("Here")
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let outline = try #require((panel.subviews.first as? NSScrollView)?.documentView as? NSOutlineView)
        panel.currentURL = here
        func node(_ url: URL) -> FoldersPanel.Node? {
            (0..<outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? FoldersPanel.Node }
                .first { FilePath.canonical($0.url.path) == FilePath.canonical(url.path) }
        }
        try #require(await eventually { node(here) != nil })
        outline.expandItem(try #require(node(here)))
        try #require(await eventually { node(s.path("Here/Old")) != nil })
        try FileManager.default.createDirectory(at: s.path("Here/New"), withIntermediateDirectories: false)
        #expect(await eventually { node(s.path("Here/New")) != nil })
        try FileManager.default.removeItem(at: s.path("Here/Old"))
        #expect(await eventually { node(s.path("Here/Old")) == nil })
    }

    /// #15: a double-click on one of several selected items opens them all (Finder); one click on it, left alone,
    /// still makes it the only one.
    @Test func aDoubleClickOnTheSelectionOpensItAll() async throws {
        let s = try Scratch("double-click")
        for n in ["a.txt", "b.txt", "c.txt"] { try s.file(n, n) }
        let model = DirectoryModel(location: s.url, prefetchFolders: false)
        model.reload()
        try #require(await eventually { !model.isLoading && model.rows.count == 3 })
        let list = ItemListView(model: model)
        let opener = Opener()
        list.delegate = opener
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = list
        window.contentView = scroll
        defer { window.close() }
        list.frame = scroll.bounds
        list.computeLayout()
        let saved = ItemListView.doubleClickInterval
        ItemListView.doubleClickInterval = { 0.2 }
        defer { ItemListView.doubleClickInterval = saved }
        func click(_ type: NSEvent.EventType, count: Int) throws {
            let f = list.frames[0]
            let e = try #require(
                NSEvent.mouseEvent(
                    with: type, location: list.convert(CGPoint(x: f.midX, y: f.midY), to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
            if type == .leftMouseDown { list.mouseDown(with: e) } else { list.mouseUp(with: e) }
        }
        model.selection = Set(model.rows.map(\.item.url))
        try click(.leftMouseDown, count: 1); try click(.leftMouseUp, count: 1)
        #expect(model.selection.count == 3)  // not yet: it may be a double-click
        try click(.leftMouseDown, count: 2); try click(.leftMouseUp, count: 2)
        #expect(opener.opened.map { Set($0.map(\.name)) } == [["a.txt", "b.txt", "c.txt"]])
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.selection.count == 3)  // the collapse was called off
        try click(.leftMouseDown, count: 1); try click(.leftMouseUp, count: 1)
        #expect(await eventually { model.selection == [model.rows[0].item.url] })
    }

    /// #15: dropping apps on the library follows the same modifiers as every other drop target.
    @Test func installDropsFollowTheModifiers() {
        #expect(AppsGridView.installOperation(sameVolume: true, modifiers: []) == .move)
        #expect(AppsGridView.installOperation(sameVolume: false, modifiers: []) == .copy)
        #expect(AppsGridView.installOperation(sameVolume: true, modifiers: .option) == .copy)
        #expect(AppsGridView.installOperation(sameVolume: false, modifiers: .command) == .move)
    }

    private final class Opener: ItemListViewDelegate {
        var opened: [[FileItem]] = []
        func itemList(_ view: ItemListView, open items: [FileItem], inNewTab: Bool) { opened.append(items) }
        func itemList(_ view: ItemListView, menuFor item: FileItem?) -> NSMenu? { nil }
        func itemList(_ view: ItemListView, drop urls: [URL], onto folder: URL, operation: NSDragOperation, event: NSEvent?) {}
        func itemList(_ view: ItemListView, rename item: FileItem, to name: String) {}
        func itemListDidBecomeActive(_ view: ItemListView) {}
        func itemList(_ view: ItemListView, hovered item: FileItem?) {}
        func itemListBackgroundDoubleClicked(_ view: ItemListView) {}
        func itemList(_ view: ItemListView, middleClicked item: FileItem) {}
        func itemListQuickLook(_ view: ItemListView) {}
    }

    /// #16: VoiceOver hears what an item's cloud badge shows, and can download it as the badge's click does.
    @Test func voiceOverHearsAndUsesTheCloudBadge() async throws {
        let account = UUID().uuidString.lowercased()
        let root = try #require(URL(string: "gdrive://\(account)/my-drive/"))
        let previous = CloudOfflineHub.service
        let offline = DemoOfflineService()
        let file = root.appendingPathComponent("report.pdf")
        offline.states[file] = .cloudOnly
        CloudOfflineHub.service = offline
        RemoteFS.use(OneFileProvider(file), for: root)
        defer { RemoteFS.use(nil, for: root); CloudOfflineHub.service = previous; ItemListView.downloadForTesting = nil }
        let model = DirectoryModel(location: root, prefetchFolders: false)
        model.reload()
        try #require(await eventually { !model.isLoading && model.rows.count == 1 })
        let list = ItemListView(model: model)
        let element = ItemAccessibilityElement(list: list, index: 0)
        let value = try #require(element.accessibilityValue() as? String)
        #expect(value.contains(try #require(CloudState.cloudOnly.help)), "\(value)")
        var downloaded: [URL] = []
        ItemListView.downloadForTesting = { downloaded.append($0.url) }
        let action = try #require(element.accessibilityCustomActions()?.first)
        #expect(action.name == "Download" && action.handler?() == true && downloaded == [file])
    }

    /// #16: a place is the same VoiceOver element across redraws, and VO-Shift-M shows its menu.
    @Test func placesAreStableForVoiceOverAndHaveTheirMenu() throws {
        let panel = PlacesPanel(frame: CGRect(x: 0, y: 0, width: 240, height: 500))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        defer { window.close() }
        let home = PlaceEntry(title: "Home", url: URL(fileURLWithPath: NSHomeDirectory()), icon: "user-home", section: .places)
        panel.rows = [.init(kind: .entry(home), y: 0, height: 28)]
        #expect(PlaceAccessibilityElement(panel: panel, index: 0) == PlaceAccessibilityElement(panel: panel, index: 0))
        #expect(PlaceAccessibilityElement(panel: panel, index: 0).hash == PlaceAccessibilityElement(panel: panel, index: 0).hash)
        var titles: [String] = []
        PlaceAccessibilityElement.presentForTesting = { titles = $0.items.map(\.title) }
        defer { PlaceAccessibilityElement.presentForTesting = nil }
        #expect(PlaceAccessibilityElement(panel: panel, index: 0).accessibilityPerformShowMenu())
        #expect(titles.contains("Open in New Tab"))
    }

    /// #16: an app's VoiceOver frame follows the app, not the row it had, when the library is filtered.
    @Test func appFramesFollowTheirAppAfterFiltering() throws {
        let s = try Scratch()
        let model = DirectoryModel(location: s.url, prefetchFolders: false)
        let apps = (0..<6).map { i in
            FileItem(url: URL(fileURLWithPath: "/Applications/Fixture-\(i).app"), name: "Fixture-\(i).app", isDirectory: true, isApplication: true)
        }
        model.searchResults = apps
        let grid = AppsGridView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        scroll.documentView = grid
        grid.updateLayout(width: 800)
        let last = try #require((grid.accessibilityChildren() as? [NSAccessibilityElement])?.last)
        let before = last.accessibilityFrameInParentSpace()
        model.searchResults = [apps[5]]
        grid.updateLayout(width: 800)
        let first = try #require((grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        #expect(
            last.accessibilityFrameInParentSpace() == first.accessibilityFrameInParentSpace() && before != first.accessibilityFrameInParentSpace())
    }

    /// #18: a stream starts when its item says it's ready (no polling), and never when it failed.
    @Test func aPlayerItemIsAwaitedNotPolled() async throws {
        let s = try Scratch("settled")
        // One second of 8 kHz mono silence.
        var wav = Data("RIFF".utf8)
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        le32(36 + 8000); wav.append(Data("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(8000); le32(8000); le16(1); le16(8)
        wav.append(Data("data".utf8)); le32(8000); wav.append(Data(repeating: 128, count: 8000))
        let good = s.path("silence.wav"), bad = s.path("broken.wav")
        try wav.write(to: good)
        try Data("not audio".utf8).write(to: bad)
        var answers: [String: Bool] = [:]
        var keep: [NSKeyValueObservation] = [], players: [AVPlayer] = []
        for (name, url) in [("good", good), ("bad", bad)] {
            let player = AVPlayer(url: url)  // an item is only read once a player has it
            players.append(player)
            keep.append(InformationPanel.whenSettled(try #require(player.currentItem)) { answers[name] = $0 })
        }
        #expect(await eventually { answers.count == 2 })
        #expect(answers == ["good": true, "bad": false])
        withExtendedLifetime((keep, players)) {}
    }

    /// #18: Settings' tabs show only their own buttons (icon-only toolbar), set when the window appears, not a turn later.
    @Test func settingsTabsAreIconOnlyWhenShown() throws {
        let settings = SettingsWindowController(page: "Advanced")
        let window = try #require(settings.window)
        defer { window.close() }
        window.orderFront(nil)
        #expect(window.toolbar?.displayMode == .iconOnly)
    }

    /// #22: an account's avatar is made once per picture and size, not decoded again on every Places redraw.
    @Test func avatarsAreMadeOnce() {
        let a = BrandMarks.avatar(nil, name: "Ann", email: "ann@example.invalid", size: 20)
        #expect(BrandMarks.avatar(nil, name: "Ann", email: "ann@example.invalid", size: 20) === a)
        #expect(BrandMarks.avatar(nil, name: "Ann", email: "ann@example.invalid", size: 26) !== a)
        #expect(BrandMarks.avatar(Data([1, 2, 3]), name: "Ann", email: "ann@example.invalid", size: 20) !== a)
    }

    private final class OneFileProvider: RemoteProvider {
        let file: URL
        init(_ file: URL) { self.file = file }
        func list(_ folder: URL) throws -> [FileItem] { [FileItem(url: file, name: file.lastPathComponent, isDirectory: false, size: 10)] }
        func rootTitle(_ url: URL) -> String { "One" }
        func download(_ remote: URL, into localFolder: URL) throws -> URL { throw CocoaError(.featureUnsupported) }
        func upload(_ local: URL, into remoteFolder: URL) throws { throw CocoaError(.featureUnsupported) }
        func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
        func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
        func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
        func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
        func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    }
}
