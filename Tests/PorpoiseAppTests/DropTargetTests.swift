import AppKit
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// A drag as AppKit hands it to a drop target: a pasteboard, the source's operations, a place in the window.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("porpoise-drop-test-\(UUID().uuidString)"))
    var mask: NSDragOperation
    var location: NSPoint
    let sequence = Int.random(in: 1_000_000...9_000_000)
    init(_ urls: [URL], mask: NSDragOperation, at location: NSPoint = .zero) {
        self.mask = mask
        self.location = location
        super.init()
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }
    deinit { pasteboard.releaseGlobally() }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { sequence }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

private final class TabDrops: TabBarDelegate {
    var folder: URL
    var dropped: [(urls: [URL], operation: NSDragOperation)] = []
    var selected: [Int] = []
    init(folder: URL) { self.folder = folder }
    func tabBar(_ bar: TabBarView, select index: Int) { selected.append(index) }
    func tabBar(_ bar: TabBarView, close index: Int) {}
    func tabBarNewTab(_ bar: TabBarView, duplicate index: Int?) {}
    func tabBar(_ bar: TabBarView, move from: Int, to: Int) {}
    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu? { nil }
    func tabBar(_ bar: TabBarView, folderAt index: Int) -> URL? { folder }
    func tabBar(_ bar: TabBarView, drop urls: [URL], onto index: Int, operation: NSDragOperation) { dropped.append((urls, operation)) }
    func tabBar(_ bar: TabBarView, detach index: Int) {}
}

/// One drop policy for every target: the items a drag carries (remote ones too), the operation the cursor shows and
/// the drop then does, which folders take them, and spring-loading that works during a drag.
@Suite(.serialized, .isolatedSettings) @MainActor struct DropTargetTests {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let file = URL(fileURLWithPath: "/tmp/porpoise-dragged.txt")
    let remote = URL(string: "sftp://me@host/home/me/report.txt")!

    /// Runs `body` as if `keys` were held: the live keyboard (someone at the Mac, keys another process injects) never
    /// reaches these tests.
    private func holding<T>(_ keys: NSEvent.ModifierFlags, _ body: () throws -> T) rethrows -> T {
        let saved = DropTargetPolicy.heldModifiers
        DropTargetPolicy.heldModifiers = { keys }
        defer { DropTargetPolicy.heldModifiers = saved }
        return try body()
    }

    @Test func dragsCarryRemoteItemsAndTheSourcesOperation() { holding([]) { dragsCarryRemoteItemsAndTheSourcesOperationWithoutKeys() } }

    private func dragsCarryRemoteItemsAndTheSourcesOperationWithoutKeys() {
        let drag = FakeDrag([file, remote, URL(string: "https://example.com/")!], mask: [.copy])
        #expect(DropTargetPolicy.urls(drag) == [file, remote])
        DropTargetPolicy.dragEnded()
        // Without a modifier: the menu when the source allows it, else what it allows (a copy-only source copies).
        #expect(DropTargetPolicy.operation(for: drag) == .copy)
        drag.mask = [.copy, .move, .generic]
        #expect(DropTargetPolicy.operation(for: drag) == .generic)
        drag.mask = [.copy, .move]
        #expect(DropTargetPolicy.operation(for: drag) == .move)
    }

    @Test func foldersTakeItemsByOneRule() {
        #expect(DropTargetPolicy.accepts([file, remote], into: home))
        #expect(DropTargetPolicy.accepts([file], into: URL(string: "sftp://me@host/home/me/")!))
        #expect(!DropTargetPolicy.accepts([], into: home))
        #expect(!DropTargetPolicy.accepts([file], into: URL(string: "recent:/files")!))
        #expect(!DropTargetPolicy.accepts([file], into: URL(string: "smb://server/share")!))
        // Onto itself, or into the folder all of them are in already: nothing to do.
        #expect(!DropTargetPolicy.accepts([home], into: home))
        #expect(!DropTargetPolicy.accepts([file], into: URL(fileURLWithPath: "/tmp")))
    }

    /// A tab used to read file URLs only (items from a server or a cloud account were dropped silently) and to ask
    /// with the menu whatever the cursor showed.
    @Test func aTabTakesRemoteItemsWithTheOperationItShows() { holding([]) { aTabTakesRemoteItemsWithoutKeys() } }

    /// Held keys choose the operation, the cursor's and the drop's alike: ⌥ copies, ⌘ moves, ⌘⌥ links.
    @Test func heldKeysChooseTheOperation() {
        let drag = FakeDrag([file], mask: [.copy, .move, .generic])
        #expect(DropTargetPolicy.operation(for: drag, modifiers: [.option]) == .copy)
        #expect(DropTargetPolicy.operation(for: drag, modifiers: [.command]) == .move)
        #expect(DropTargetPolicy.operation(for: drag, modifiers: [.command, .option]) == .link)
        #expect(DropTargetPolicy.operation(for: drag, modifiers: [.shift]) == .generic)
        // A tab reads the keys held now: with ⌘ held, the copy-only remote drag shows a move, and drops one.
        let bar = TabBarView(frame: CGRect(x: 0, y: 0, width: 600, height: 30))
        let drops = TabDrops(folder: home)
        bar.delegate = drops
        bar.titles = ["One", "Two"]
        bar.layoutSubtreeIfNeeded()
        let remoteDrag = FakeDrag([remote], mask: [.copy], at: bar.convert(CGPoint(x: 20, y: 15), to: nil))
        holding([.command]) {
            #expect(bar.draggingUpdated(remoteDrag) == .move)
            #expect(bar.performDragOperation(remoteDrag))
        }
        #expect(drops.dropped.last?.operation == .move)
        holding([.option]) { #expect(bar.draggingUpdated(remoteDrag) == .copy) }
    }

    private func aTabTakesRemoteItemsWithoutKeys() {
        let bar = TabBarView(frame: CGRect(x: 0, y: 0, width: 600, height: 30))
        let drops = TabDrops(folder: home)
        bar.delegate = drops
        bar.titles = ["One", "Two"]
        bar.layoutSubtreeIfNeeded()
        let drag = FakeDrag([remote], mask: [.copy], at: bar.convert(CGPoint(x: 20, y: 15), to: nil))
        let shown = bar.draggingUpdated(drag)
        #expect(shown == .copy)
        #expect(bar.performDragOperation(drag))
        #expect(drops.dropped.count == 1 && drops.dropped.first?.urls == [remote] && drops.dropped.first?.operation == shown)
        // A tab showing a folder that takes nothing: the forbidden cursor, and no drop.
        drops.folder = URL(string: "recent:/files")!
        let other = FakeDrag([remote], mask: [.copy], at: bar.convert(CGPoint(x: 20, y: 15), to: nil))
        #expect(bar.draggingUpdated(other) == [])
        #expect(!bar.performDragOperation(other))
    }

    /// A drag inside the app runs an event-tracking run loop: spring-loading must still open what it rests on.
    @Test func springLoadingWorksDuringADrag() {
        // AppKit makes event tracking one of the common run loop modes when the application starts: run alone, this
        // suite has to start it itself.
        _ = NSApplication.shared
        let loader = SpringLoader(delay: 0.05)
        var opened = 0
        loader.hover(1) { opened += 1 }
        loader.hover(1) { opened += 1 }  // updates while resting leave the pause alone
        let end = Date().addingTimeInterval(eventualTimeout)
        while opened == 0 && Date() < end { RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01)) }
        #expect(opened == 1)
        loader.hover(2) { opened += 10 }
        loader.hover(nil) { opened += 100 }
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.2))
        #expect(opened == 1)
    }
}
