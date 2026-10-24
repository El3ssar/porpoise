import AppKit
import PorpoiseCore
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
}
