import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// Column view (RM-8): Finder's columns, keys, clicks, widths and preview, on the pane's own list.
@Suite(.serialized, .isolatedSettings) @MainActor struct ColumnViewTests {
    init() {
        _ = NSApplication.shared
        // The machine's own mouse may be in use while the tests run.
        ColumnBrowserView.mouseIsDown = { false }
    }

    /// What the pane asks of its window: recorded.
    final class Recorder: ViewContainerDelegate {
        var opened: [[URL]] = []
        var menus: [URL?] = []
        var drops: [(urls: [URL], folder: URL)] = []
        var renames: [(URL, String)] = []
        var quickLooks = 0
        var activations = 0
        /// Opening one folder goes into it, as the window does.
        var navigates = false
        func containerDidBecomeActive(_ c: ViewContainer) { activations += 1 }
        func containerDidChangeURL(_ c: ViewContainer) {}
        func containerSelectionChanged(_ c: ViewContainer) {}
        func container(_ c: ViewContainer, open items: [FileItem], inNewTab: Bool) {
            opened.append(items.map(\.url))
            if navigates, items.count == 1, items[0].isBrowsableFolder, !inNewTab { c.setURL(items[0].url) }
        }
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
    func tree() throws -> Scratch {
        let s = try Scratch()
        try s.file("A/A1/deep.txt", "deep")
        try s.file("A/a.txt", "a")
        try s.folder("B")
        try s.file("f.txt", "f")
        return s
    }

    func pane(_ url: URL, width: CGFloat = 1100) async throws -> (ViewContainer, NSWindow, Recorder) {
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

    func key(_ code: UInt16, to view: NSView, _ mods: NSEvent.ModifierFlags = []) {
        view.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
    }
    let right: UInt16 = 124, left: UInt16 = 123

    /// A click on `url`'s row in `list` (down and up), as the user makes it.
    /// `release`: false presses only (the button stays down: a drag may start); `release(_:in:)` lets it go.
    func click(_ url: URL, in list: ItemListView, count: Int = 1, type: NSEvent.EventType = .leftMouseDown, release: Bool = true) throws {
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
        if type == .leftMouseUp { return list.mouseUp(with: event(.leftMouseUp)) }
        list.mouseDown(with: event(.leftMouseDown))
        guard release else { return }
        list.mouseUp(with: event(.leftMouseUp))
    }

    func browser(_ pane: ViewContainer) throws -> ColumnBrowserView { try #require(pane.columnBrowser) }

    /// Six folders deep: L1/…/L6, and in the root and each of them a folder S and a file f.txt; L1 has 60 more files.
    func deepTree() throws -> Scratch {
        let s = try Scratch()
        try s.file("f.txt", "0")
        try s.folder("S")
        for k in 1...6 {
            try s.file("\(level(k))/f.txt", "\(k)")
            try s.folder("\(level(k))/S")
        }
        for n in 0..<60 { try s.file("L1/file \(n).txt", "\(n)") }
        return s
    }

    /// The path of the folder `depth` levels down: L1/…/L`depth`.
    func level(_ depth: Int) -> String { (1...max(1, depth)).map { "L\($0)" }.joined(separator: "/") }

    /// Every column shown has listed its folder.
    func listed(_ b: ColumnBrowserView) async throws {
        try #require(await eventually { (b.before + [b.after].compactMap { $0 }).allSatisfy { !$0.model.isLoading } })
    }

    /// The pane in the folder `depth` levels down, `item` (in it) selected once it has listed.
    func go(_ pane: ViewContainer, _ s: Scratch, to depth: Int, selecting item: String) async throws {
        pane.setURL(depth == 0 ? s.url : s.path(level(depth)))
        let u = s.path(depth == 0 ? item : "\(level(depth))/\(item)")
        try #require(await eventually { pane.model.index(of: u) != nil })
        pane.list.select(u)
        try await listed(try browser(pane))
    }
}
