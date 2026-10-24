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
}
