import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// Desktop Mode with Stage Manager on or off: Porpoise hides Finder's desktop items itself and puts them back, a plain
/// click on empty space reveals the desktop as a wallpaper click does, and disks sit in the top right corner, where
/// they are ejected rather than trashed.
@MainActor @Suite(.serialized, .isolatedSettings) struct DesktopModeEverywhereTests {
    init() { _ = NSApplication.shared }

    private let root = URL(fileURLWithPath: "/", isDirectory: true)
    private var rootItem: FileItem { FileItem(url: root, name: "Startup Disk", isDirectory: true) }

    /// The disks a test's desktop lists, changed while it runs (they are listed off the main thread).
    private final class Disks: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [FileItem]
        init(_ items: [FileItem]) { stored = items }
        var items: [FileItem] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Both preference domains in memory, as Stage Manager users have them: Finder's items and widgets shown.
    private final class FakeSystem {
        var domains: [String: [String: Any]] = [
            "com.apple.WindowManager": ["GloballyEnabled": true, "EnableStandardClickToShowDesktop": false], "com.apple.finder": [:],
        ]
        lazy var preferences = DesktopPreferences(
            read: { [unowned self] in domains[$0]?[$1] }, write: { [unowned self] in domains[$0, default: [:]][$1] = $2 })
        func value(_ key: String) -> Any? { domains["com.apple.WindowManager"]?[key] }
        var hidden: Bool { DesktopSystemSettings.hiddenKeys.allSatisfy { value($0) as? Bool == true } }
        var untouched: Bool {
            DesktopSystemSettings.hiddenKeys.allSatisfy { value($0) == nil } && value("GloballyEnabled") as? Bool == true
                && value("EnableStandardClickToShowDesktop") as? Bool == false
        }
    }

    private func makeDesktop(
        location: URL, volumes: @escaping @Sendable () -> [FileItem] = { [] }, reveal: @escaping @MainActor () -> Void = {}
    ) -> DesktopWindowController {
        let controller = DesktopWindowController(
            location: location, displays: { [DesktopDisplay(id: 11, frame: NSRect(x: 0, y: 0, width: 640, height: 480))] },
            volumes: volumes, revealDesktop: reveal)
        controller.start()
        return controller
    }

    @Test func enablingHidesFindersItemsWithStageManagerOnAndDisablingOrQuittingPutsThemBack() throws {
        let scratch = try Scratch(), system = FakeSystem()
        let mode = DesktopModeController(
            environment: { DesktopEnvironment.inspect(system.preferences) },
            systemSettings: { DesktopSystemSettings(preferences: system.preferences, store: Settings.store) },
            makeWindow: { makeDesktop(location: scratch.url) })
        defer { mode.stop() }
        mode.start()
        #expect(system.untouched && !mode.isEnabled)
        mode.setEnabled(true)
        #expect(mode.isEnabled && mode.pausedStatusItem == nil && system.hidden)
        #expect(system.value("GloballyEnabled") as? Bool == true && system.value("EnableStandardClickToShowDesktop") as? Bool == false)
        #expect(mode.statusLine.0 == true)
        mode.setEnabled(false)
        #expect(!mode.isEnabled && system.untouched)
        mode.setEnabled(true)
        #expect(system.hidden)
        mode.stop()
        #expect(system.untouched && Settings.shared.desktopModeEnabled)
    }

    @Test func aLaunchWithDesktopModeOffPutsBackWhatACrashedSessionLeftHidden() throws {
        let scratch = try Scratch(), system = FakeSystem()
        DesktopSystemSettings(preferences: system.preferences, store: Settings.store).apply()
        #expect(system.hidden && Settings.store.object(forKey: DesktopSystemSettings.savedKey) != nil)
        let mode = DesktopModeController(
            environment: { DesktopEnvironment.inspect(system.preferences) },
            systemSettings: { DesktopSystemSettings(preferences: system.preferences, store: Settings.store) },
            makeWindow: { makeDesktop(location: scratch.url) })
        defer { mode.stop() }
        mode.start()
        #expect(system.untouched && Settings.store.object(forKey: DesktopSystemSettings.savedKey) == nil)
    }

    @Test func anUnrecognizedSettingChangesNothingAndPausing() throws {
        let scratch = try Scratch(), system = FakeSystem()
        system.domains["com.apple.finder"]?["CreateDesktop"] = "true"  // a string, as `defaults write` without -bool leaves it
        let mode = DesktopModeController(
            environment: { DesktopEnvironment.inspect(system.preferences) },
            systemSettings: { DesktopSystemSettings(preferences: system.preferences, store: Settings.store) },
            makeWindow: { makeDesktop(location: scratch.url) })
        defer { mode.stop() }
        mode.setEnabled(true)
        #expect(!mode.isEnabled && mode.environment.conflicts.contains(.unreadable))
        #expect(system.untouched && Settings.store.object(forKey: DesktopSystemSettings.savedKey) == nil)
    }

    @Test func aPausedDesktopLeavesFindersIconsAsTheUserHadThem() throws {
        let scratch = try Scratch(), system = FakeSystem()
        // macOS takes the item settings but keeps the widgets (a managed Mac, say).
        let partly = DesktopPreferences(
            read: { system.preferences.read($0, $1) },
            write: { domain, key, value in if !key.contains("Widgets") { system.preferences.write(domain, key, value) } })
        let mode = DesktopModeController(
            environment: { DesktopEnvironment.inspect(partly) },
            systemSettings: { DesktopSystemSettings(preferences: partly, store: Settings.store) },
            makeWindow: { makeDesktop(location: scratch.url) })
        defer { mode.stop() }
        mode.setEnabled(true)
        #expect(!mode.isEnabled && mode.pausedStatusItem != nil && mode.environment.conflicts == [.widgets, .stageWidgets])
        #expect(system.untouched)
    }

    @Test func settingsMacOSRefusesToChangePauseTheDesktopAndSaySo() throws {
        let scratch = try Scratch()
        let locked = DesktopPreferences(read: { _, _ in nil }, write: { _, _, _ in })
        let mode = DesktopModeController(
            environment: { DesktopEnvironment.inspect(locked) },
            systemSettings: { DesktopSystemSettings(preferences: locked, store: Settings.store) },
            makeWindow: { makeDesktop(location: scratch.url) })
        defer { mode.stop() }
        mode.setEnabled(true)
        #expect(!mode.isEnabled && mode.pausedStatusItem != nil)
        #expect(mode.statusLine.1.contains("macOS kept these desktop settings") && mode.statusLine.1.contains("Show widgets"))
    }

    private func mouse(
        _ grid: DesktopGridView, _ type: NSEvent.EventType, at point: NSPoint, modifiers: NSEvent.ModifierFlags = [], count: Int = 1
    ) throws -> NSEvent {
        let window = try #require(grid.window)
        return try #require(
            NSEvent.mouseEvent(
                with: type, location: grid.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: count, pressure: 1))
    }

    @Test func onlyAPlainClickOnEmptyDesktopSpaceRevealsTheDesktop() async throws {
        let scratch = try Scratch()
        _ = try scratch.file("one.txt")
        var reveals = 0
        let controller = makeDesktop(location: scratch.url, reveal: { reveals += 1 })
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 1 })
        let grid = try #require(controller.grids.first)
        grid.window?.contentView?.layoutSubtreeIfNeeded(); grid.relayout()
        let emptyCell = grid.geometry.frame(for: 3), empty = NSPoint(x: emptyCell.midX, y: emptyCell.midY)
        #expect(grid.index(at: empty) == nil)
        func click(_ point: NSPoint, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) throws {
            grid.mouseDown(with: try mouse(grid, .leftMouseDown, at: point, modifiers: modifiers, count: count))
            grid.mouseUp(with: try mouse(grid, .leftMouseUp, at: point, modifiers: modifiers, count: count))
        }
        try click(empty)
        #expect(reveals == 1)
        // The windows come back with the next click, as with macOS's own wallpaper click.
        try click(empty)
        #expect(reveals == 2)
        let icon = grid.iconRect(0)
        try click(NSPoint(x: icon.midX, y: icon.midY))
        #expect(reveals == 2 && grid.model.selection == [grid.model.rows[0].item.url])
        for modifiers: NSEvent.ModifierFlags in [.command, .shift, .option] { try click(empty, modifiers: modifiers) }
        #expect(reveals == 2)
        // A double-click's second click is not another wallpaper click.
        try click(empty, count: 2)
        #expect(reveals == 2)
        // Selecting with a band is not a click, but a press that barely moves still is.
        grid.mouseDown(with: try mouse(grid, .leftMouseDown, at: empty))
        grid.mouseDragged(with: try mouse(grid, .leftMouseDragged, at: NSPoint(x: icon.midX, y: icon.midY)))
        grid.mouseUp(with: try mouse(grid, .leftMouseUp, at: NSPoint(x: icon.midX, y: icon.midY)))
        #expect(reveals == 2)
        grid.mouseDown(with: try mouse(grid, .leftMouseDown, at: empty))
        grid.mouseDragged(with: try mouse(grid, .leftMouseDragged, at: NSPoint(x: empty.x + 2, y: empty.y + 2)))
        grid.mouseUp(with: try mouse(grid, .leftMouseUp, at: NSPoint(x: empty.x + 2, y: empty.y + 2)))
        #expect(reveals == 3)
    }

    @Test func disksComeFirstInTheTopRightCornerAndFollowMountChanges() async throws {
        let scratch = try Scratch()
        _ = try scratch.file("a.txt")
        let disks = Disks([rootItem]), item = rootItem
        let controller = makeDesktop(location: scratch.url, volumes: { disks.items })
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 2 })
        let grid = try #require(controller.grids.first), model = try #require(controller.model)
        grid.window?.contentView?.layoutSubtreeIfNeeded(); grid.relayout()
        #expect(model.rows.map(\.item.name) == ["Startup Disk", "a.txt"])
        #expect(controller.gridPreferences.corner == .topRight)
        let disk = grid.geometry.frame(for: grid.slots[0]), file = grid.geometry.frame(for: grid.slots[1])
        #expect(disk.maxX > grid.bounds.width - 140 && disk.minY < 140)
        #expect(file.minX == disk.minX && file.minY > disk.minY)
        disks.items = []
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didUnmountNotification, object: NSWorkspace.shared)
        #expect(await eventually { model.rows.map(\.item.name) == ["a.txt"] })
        disks.items = [item]
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared)
        #expect(await eventually { model.rows.first?.item.url == root })
        // A rename is announced before macOS lists the new name: the desktop looks again a moment later.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didRenameVolumeNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(300))
        disks.items = [FileItem(url: root, name: "Renamed Disk", isDirectory: true)]
        #expect(await eventually { model.rows.first?.item.name == "Renamed Disk" })
    }

    @Test func aDiskIsEjectedInsteadOfTrashedAndIsNeverRenamedCutDuplicatedOrDeleted() async throws {
        let scratch = try Scratch(), elsewhere = try Scratch()
        let file = try scratch.file("file.txt", "unchanged")
        // A stand-in disk: a scratch folder, so even a broken guard could never reach a real one.
        let disk = try elsewhere.folder("USB"), diskItem = FileItem(url: disk, name: "USB", isDirectory: true)
        let controller = makeDesktop(location: scratch.url, volumes: { [diskItem] })
        defer { controller.close() }
        var ejected: [[URL]] = []
        controller.ejectVolumes = { ejected.append($0) }
        controller.isEjectable = { _ in true }  // as an external disk would be
        try #require(await eventually { controller.model?.rows.count == 2 })
        let model = try #require(controller.model)
        model.selection = [disk]
        let menu = controller.desktopMenu(for: 0)
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Eject") && !titles.contains("Move to Trash") && !titles.contains("Delete"))
        #expect(!titles.contains("Rename…") && !titles.contains("Cut") && !titles.contains("Duplicate Here"))
        #expect(titles.contains { $0.hasPrefix("Open") })
        for action in [
            #selector(DesktopWindowController.renameItem(_:)), #selector(DesktopWindowController.cut(_:)),
            #selector(DesktopWindowController.duplicateItem(_:)), #selector(DesktopWindowController.deleteItem(_:)),
        ] {
            #expect(!controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")), "\(action)")
        }
        #expect(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(DesktopWindowController.ejectVolume(_:)), keyEquivalent: "")))
        controller.renameItem(nil); controller.cut(nil); controller.duplicateItem(nil); controller.deleteItem(nil)
        controller.itemList(try #require(controller.grids.first), rename: diskItem, to: "Renamed")
        #expect(ejected.isEmpty && FileOperationsController.shared.cutURLs.isEmpty)
        controller.moveToTrash(nil)
        controller.ejectVolume(nil)
        #expect(ejected == [[disk], [disk]])
        #expect(FileManager.default.fileExists(atPath: disk.path))
        // A file alone keeps every command; ⌘E has no disk to eject.
        model.selection = [file]
        #expect(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(DesktopWindowController.renameItem(_:)), keyEquivalent: "")))
        #expect(!controller.validateMenuItem(NSMenuItem(title: "", action: #selector(DesktopWindowController.ejectVolume(_:)), keyEquivalent: "")))
        #expect(controller.desktopMenu(for: 1).items.contains { $0.title == "Move to Trash" })
        #expect(scratch.read("file.txt") == "unchanged")
    }

    @Test func trashingAMixedSelectionNeverEjectsTheDisksInIt() async throws {
        let scratch = try Scratch(), elsewhere = try Scratch()
        let file = try scratch.file("file.txt", "unchanged")
        let disk = try elsewhere.folder("USB"), diskItem = FileItem(url: disk, name: "USB", isDirectory: true)
        let controller = makeDesktop(location: scratch.url, volumes: { [diskItem] })
        defer { controller.close() }
        var ejected: [[URL]] = [], trashed: [[URL]] = []
        controller.ejectVolumes = { ejected.append($0) }
        controller.trashFiles = { trashed.append($0) }
        controller.isEjectable = { _ in true }
        try #require(await eventually { controller.model?.rows.count == 2 })
        let model = try #require(controller.model)
        model.selection = [disk, file]
        #expect(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(DesktopWindowController.moveToTrash(_:)), keyEquivalent: "")))
        controller.moveToTrash(nil)
        #expect(ejected.isEmpty && trashed == [[file]])
        model.selection = [disk]
        controller.moveToTrash(nil)
        #expect(ejected == [[disk]] && trashed == [[file]])
    }

    @Test func settingsMacOSKeepsAreNotWrittenAgainOnEveryRecheck() throws {
        let scratch = try Scratch(), system = FakeSystem()
        var writes = 0
        let locked = DesktopPreferences(
            read: { system.preferences.read($0, $1) },
            write: { domain, key, value in
                writes += 1
                if !key.contains("Widgets") { system.preferences.write(domain, key, value) }
            })
        let mode = DesktopModeController(
            environment: { DesktopEnvironment.inspect(locked) },
            systemSettings: { DesktopSystemSettings(preferences: locked, store: Settings.store) },
            makeWindow: { makeDesktop(location: scratch.url) })
        defer { mode.stop() }
        mode.setEnabled(true)
        let afterFirst = writes
        #expect(!mode.isEnabled && afterFirst > 0 && system.untouched)
        // Activations, Space changes and our own writes' FSEvents recheck: nothing is written again (no flicker).
        for _ in 0..<5 { mode.checkEnvironment() }
        #expect(writes == afterFirst && system.untouched)
        // Check Again tries once more.
        mode.retry()
        #expect(writes > afterFirst && !mode.isEnabled && system.untouched)
    }

    @Test func severalIconsMoveTogetherAndKeepTheirArrangement() async throws {
        let scratch = try Scratch()
        let names = ["a", "b", "c", "d", "e"]
        let urls = try names.map { try scratch.file("\($0).txt", $0) }
        let controller = makeDesktop(location: scratch.url)
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 5 })
        let grid = try #require(controller.grids.first)
        grid.window?.contentView?.layoutSubtreeIfNeeded(); grid.relayout()
        let rows = grid.geometry.rows
        func slot(_ url: URL) throws -> Int { grid.slots[try #require(grid.model.index(of: url))] }
        func cell(_ url: URL) throws -> (Int, Int) { let s = try slot(url); return (s / rows, s % rows) }
        func center(_ slot: Int) -> NSPoint { let f = grid.geometry.frame(for: slot); return NSPoint(x: f.midX, y: f.midY) }
        // a at column 0 row 0, b at column 1 row 1: a diagonal pair.
        grid.moveItem(at: try #require(grid.model.index(of: urls[1])), to: center(rows + 1))
        try #require(try cell(urls[1]) == (1, 1))
        try #require(try cell(urls[0]) == (0, 0))
        let previous = DropTargetPolicy.heldModifiers
        DropTargetPolicy.heldModifiers = { [] }
        defer { DropTargetPolicy.heldModifiers = previous; DropTargetPolicy.dragEnded(); grid.dragAnchor = nil }
        // Picked up by b and dropped one column right and one row lower: a follows at the same distance.
        grid.model.selection = [urls[0], urls[1]]
        grid.dragAnchor = urls[1]
        let drag = FakeDrag(
            [urls[0], urls[1]], mask: [.move, .generic], at: grid.convert(center(2 * rows + 2), to: nil), source: grid)
        #expect(grid.draggingUpdated(drag) == .move && grid.performDragOperation(drag))
        grid.relayout()
        #expect(try cell(urls[0]) == (1, 1) && cell(urls[1]) == (2, 2))
        // Every icon still has a cell of its own, and no file changed.
        #expect(Set(grid.slots).count == 5)
        for (url, name) in zip(urls, names) { #expect(try String(contentsOf: url, encoding: .utf8) == name) }
        // Picked up by a and dropped where b would leave the bottom: the pair stops at the edge, still diagonal.
        grid.dragAnchor = urls[0]
        let edge = FakeDrag(
            [urls[0], urls[1]], mask: [.move, .generic], at: grid.convert(center(0 * rows + 2), to: nil), source: grid)
        #expect(grid.performDragOperation(edge))
        grid.relayout()
        #expect(try cell(urls[0]) == (0, 1) && cell(urls[1]) == (1, 2))
        #expect(Set(grid.slots).count == 5)
    }

    @Test func aDraggedDiskIsCopiedOrLinkedNeverMovedAndStillRearrangesTheDesktop() async throws {
        #expect(FileDragSource.volumes(in: [root]) == .startupDisk)
        #expect(FileDragSource.volumes(in: [URL(fileURLWithPath: NSTemporaryDirectory())]) == FileDragSource.DraggedVolumes.none)
        #expect(FileDragSource.mask(for: .outsideApplication, volumes: .ejectable) == [.copy, .link, .delete])
        #expect(FileDragSource.mask(for: .withinApplication, volumes: .ejectable) == [.copy, .link])
        // The startup disk is never copied wholesale or offered to the Trash: an alias at most.
        #expect(FileDragSource.mask(for: .outsideApplication, volumes: .startupDisk) == [.link])
        #expect(FileDragSource.mask(for: .withinApplication, volumes: .startupDisk) == [.link])
        #expect(FileDragSource.mask(for: .outsideApplication).contains(.move))
        let scratch = try Scratch()
        _ = try scratch.file("a.txt")
        let item = rootItem
        let controller = makeDesktop(location: scratch.url, volumes: { [item] })
        defer { controller.close() }
        try #require(await eventually { controller.model?.rows.count == 2 })
        let grid = try #require(controller.grids.first)
        grid.window?.contentView?.layoutSubtreeIfNeeded(); grid.relayout()
        let previous = DropTargetPolicy.heldModifiers
        DropTargetPolicy.heldModifiers = { [] }; defer { DropTargetPolicy.heldModifiers = previous; DropTargetPolicy.dragEnded() }
        grid.draggingVolumes = .startupDisk
        defer { grid.draggingVolumes = .none }
        let target = grid.geometry.frame(for: 4)
        let drag = FakeDrag([root], mask: [.link], at: grid.convert(NSPoint(x: target.midX, y: target.midY), to: nil), source: grid)
        #expect(grid.draggingUpdated(drag) == .move && grid.performDragOperation(drag))
        #expect(controller.gridPreferences.positions[grid.scope]?[root.absoluteString] == 4)
    }

    @Test func theStartupDiskOffersNoEjectAndNeverGoesToTheTrash() async throws {
        let scratch = try Scratch()
        _ = try scratch.file("file.txt")
        let item = rootItem
        let controller = makeDesktop(location: scratch.url, volumes: { [item] })
        defer { controller.close() }
        var ejected: [[URL]] = []
        controller.ejectVolumes = { ejected.append($0) }
        try #require(await eventually { controller.model?.rows.count == 2 })
        let model = try #require(controller.model)
        model.selection = [root]
        let titles = controller.desktopMenu(for: 0).items.map(\.title)
        #expect(!titles.contains("Eject") && !titles.contains("Move to Trash"))
        for action in [#selector(DesktopWindowController.ejectVolume(_:)), #selector(DesktopWindowController.moveToTrash(_:))] {
            #expect(!controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")), "\(action)")
        }
        controller.ejectVolume(nil); controller.moveToTrash(nil)
        #expect(ejected.isEmpty)
    }
}

@MainActor @Suite struct DiskDragPasteboardTests {
    @Test func aDraggedDiskCarriesFindersNodeSoTheDocksTrashOffersEject() throws {
        let disk = FileDragWriter(url: URL(fileURLWithPath: "/", isDirectory: true), allURLs: nil, isVolume: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("porpoise-disk-drag-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(disk.writableTypes(for: pasteboard) == [.fileURL, FileDragWriter.finderNode])
        let node = try #require(disk.pasteboardPropertyList(forType: FileDragWriter.finderNode) as? String)
        #expect(node.hasPrefix("file:///.file/id="))
        #expect(disk.pasteboardPropertyList(forType: .fileURL) as? String == "file:///")
        let scratch = try Scratch()
        let file = FileDragWriter(url: try scratch.file("a.txt"), allURLs: [])
        #expect(file.writableTypes(for: pasteboard) == [.fileURL, FileDragWriter.filenames])
        // The drag source finds the disks among the items itself, from one look at the mount table.
        let items = FileDragSource.items([URL(fileURLWithPath: "/"), scratch.url]) { _ in nil }
        let writers = items.compactMap { $0.item as? FileDragWriter }
        #expect(writers.map { $0.writableTypes(for: pasteboard).contains(FileDragWriter.finderNode) } == [true, false])
    }
}
