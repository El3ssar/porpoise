import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Disk, network and Spotlight reads kept off the main thread (W-236, W-235 pattern 3).
@Suite(.serialized, .isolatedSettings) @MainActor struct MainThreadSweepTests {
    init() { _ = NSApplication.shared }

    private func text(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { text(in: $0) }
    }

    /// Selects the row named `name` (by its own URL: a folder's ends with a slash).
    private func select(_ name: String, in pane: ViewContainer) throws {
        pane.list.select(try #require(pane.model.rows.first { $0.item.name == name }).item.url)
    }

    private func pane(_ url: URL) async throws -> (ViewContainer, NSWindow) {
        let pane = ViewContainer(url: url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        try #require(await eventually { !pane.model.isLoading && !pane.model.rows.isEmpty })
        return (pane, window)
    }

    /// #12: the Information panel shows a listed item at once and reads the rest (a big folder's count, permissions,
    /// tags, Spotlight) off the main thread; what was read for an item since left behind never lands.
    @Test func theInformationPanelReadsOffTheMainThread() async throws {
        let s = try Scratch()
        try s.folder("Big")
        for i in 0..<3000 { FileManager.default.createFile(atPath: s.path("Big/f\(i)").path, contents: nil) }
        try s.file("note.txt", "hello")
        let (pane, window) = try await pane(s.url)
        defer { window.close() }
        let panel = InformationPanel(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        try select("Big", in: pane)
        panel.show(hovered: nil, container: pane)
        #expect(text(in: panel).contains("Big"), "the listed folder's name shows at once")
        #expect(!text(in: panel).contains { $0.contains("3,000") || $0.contains("3000") }, "its count isn't read on the main thread")
        #expect(await eventually { text(in: panel).contains { $0.contains("3,000 items") || $0.contains("3000 items") } })
        // Rushed past: only the item the panel ends on gets its details.
        try select("Big", in: pane)
        panel.show(hovered: nil, container: pane)
        try select("note.txt", in: pane)
        panel.show(hovered: nil, container: pane)
        #expect(await eventually { text(in: panel).contains("note.txt") && text(in: panel).contains { $0.hasPrefix("Read") } })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!text(in: panel).contains { $0.contains("3,000") || $0.contains("3000") })
        // Nothing selected: the folder itself, read off the main thread too.
        pane.model.selection = []
        panel.show(hovered: nil, container: pane)
        #expect(await eventually { text(in: panel).contains(s.url.lastPathComponent) })
    }

    /// #13: the Folders panel's outline callbacks never read the disk: whether a folder has subfolders is probed on
    /// its listing queue, the triangle shown until then.
    @Test func theFoldersPanelProbesForSubfoldersOffTheMainThread() async throws {
        let s = try Scratch()
        try s.folder("Has/Sub")
        try s.file("Plain/a.txt", "a")
        let panel = FoldersPanel(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let outline = try #require((panel.subviews.first as? NSScrollView)?.documentView as? NSOutlineView)
        let has = FoldersPanel.Node(s.path("Has")), plain = FoldersPanel.Node(s.path("Plain"))
        // Answered at once, nothing read yet.
        #expect(panel.outlineView(outline, isItemExpandable: has) && panel.outlineView(outline, isItemExpandable: plain))
        #expect(has.knownExpandable == nil && has.probing && plain.probing)
        #expect(await eventually { has.knownExpandable == true && plain.knownExpandable == false })
        #expect(panel.outlineView(outline, isItemExpandable: has) && !panel.outlineView(outline, isItemExpandable: plain))
        // A folder that changed on disk is probed again.
        try s.folder("Plain/New")
        plain.invalidate()
        _ = panel.outlineView(outline, isItemExpandable: plain)
        #expect(await eventually { plain.knownExpandable == true })
    }

    /// #15: in the Native theme, ordinary files and folders show their type's icon: macOS is asked once per type and
    /// size, and a folder's recolouring is done once, not per path in the draw path.
    @Test func nativeIconsAreSharedByType() throws {
        let s = try Scratch()
        try s.folder("One")
        try s.folder("Two")
        try s.file("a.txt", "a")
        try s.file("b.txt", "b")
        Settings.shared.appearancePreferences.iconTheme = "Native macOS"
        func item(_ name: String) throws -> FileItem { try #require(FileItem.load(s.path(name))) }
        let one = try item("One"), two = try item("Two"), a = try item("a.txt"), b = try item("b.txt")
        #expect(Icons.sharedNativeType(for: one) == .folder && Icons.sharedNativeType(for: a) == .plainText)
        #expect(Icons.shared.image(for: one, size: 64) === Icons.shared.image(for: two, size: 64))
        #expect(Icons.shared.image(for: a, size: 64) === Icons.shared.image(for: b, size: 64))
        // Folders macOS draws its own way keep their own icon.
        let home = try #require(FileItem.load(FileManager.default.homeDirectoryForCurrentUser))
        #expect(Icons.sharedNativeType(for: home) == nil)
        if let desktop = FileItem.load(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")) {
            #expect(Icons.sharedNativeType(for: desktop) == nil)
        }
        let app = try #require(FileItem.load(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        #expect(Icons.sharedNativeType(for: app) == nil)
    }

    /// W15: restoring a session never stats a folder on a network share (it's tried when shown); local folders that
    /// are gone are still left out.
    @Test func sessionRestoreDoesntStatNetworkFolders() throws {
        let s = try Scratch()
        #expect(SessionState.exists(s.url) && !SessionState.exists(s.path("gone")))
        #expect(SessionState.exists(URL(string: "sftp://server/x")!))
        let mounts = (try? String(contentsOfFile: "/etc/auto_master", encoding: .utf8)) ?? ""
        if mounts.contains("auto_home") { #expect(SessionState.exists(URL(fileURLWithPath: "/System/Volumes/Data/home/nobody/gone"))) }
    }

    /// V11: the Shelf works out where its items are off the main thread, and remembers those that moved with one save
    /// (it saved, and reloaded itself, once per moved item from inside the reload).
    @Test func theShelfFindsItsItemsOffTheMainThreadAndSavesOnce() async throws {
        let s = try Scratch()
        let a = try s.file("a.txt", "a"), b = try s.file("b.txt", "b")
        let store = ShelfStore(file: s.path("shelves.json"))
        store.add([a, b])
        try FileManager.default.createDirectory(at: s.path("moved"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a, to: s.path("moved/a.txt"))
        try FileManager.default.moveItem(at: b, to: s.path("moved/b.txt"))
        var saves = 0
        let observer = NotificationCenter.default.addObserver(forName: ShelfStore.changed, object: store, queue: nil) { _ in saves += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let panel = ShelfPanel(frame: CGRect(x: 0, y: 0, width: 240, height: 400), store: store)
        // Nothing moved yet on the main thread: the items as they were added.
        #expect(saves == 0 && store.current.items.map(\.url.lastPathComponent) == ["a.txt", "b.txt"])
        #expect(store.current.items.allSatisfy { !$0.url.path.contains("/moved/") })
        #expect(await eventually { store.current.items.allSatisfy { $0.url.path.contains("/moved/") } })
        try await Task.sleep(for: .milliseconds(200))
        #expect(saves == 1, "one save for both")
        _ = panel
    }
}
