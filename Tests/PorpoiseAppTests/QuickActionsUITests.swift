import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct QuickActionsUITests {
    init() { _ = NSApplication.shared }

    @Test func menuUsesClickedSplitAndKeepsTheInputSelection() async throws {
        let scratch = try Scratch(), left = try scratch.folder("Left"), right = try scratch.folder("Right")
        let services = try scratch.folder("Services"), output = scratch.path("received.bin")
        try QuickActionFixture.make(in: services, script: QuickActionFixture.recordScript(to: output))
        let first = try scratch.file("Right/first.txt"), second = try scratch.file("Right/second.txt")
        let owner = MainWindowController(urls: [left], split: [right]); defer { owner.window?.close() }
        owner.quickActions = FinderQuickActions(directories: [services])
        let secondary = try #require(owner.tab.secondary)
        try #require(await eventually { !secondary.model.isLoading && secondary.model.rows.count == 2 })
        secondary.model.selection = [first, second]
        let menu = owner.contextMenu(for: secondary.model.rows[0].item, in: secondary)
        let actions = try #require(menu.items.first { $0.title == "Quick Actions" }?.submenu)
        #expect(owner.view === secondary)
        try #require(await eventually { actions.items.first?.title == "Record" })
        let entry = try #require(actions.items.first)
        let invocation = try #require(entry.representedObject as? QuickActionInvocation)
        #expect(Set(invocation.items.map(\.url)) == [first, second])
        secondary.model.selection = [second]
        owner.runQuickAction(entry)
        let expected = Data((invocation.items.map { $0.url.path }.joined(separator: "\0") + "\0").utf8)
        #expect(await eventually(30) { (try? Data(contentsOf: output)) == expected })
    }

    @Test func emptyAreaUsesFolderAndToolbarUsesSelection() async throws {
        let scratch = try Scratch(), services = try scratch.folder("Services"), folder = try scratch.folder("Folder")
        try QuickActionFixture.make(in: services, name: "Folder Action", types: ["public.folder"])
        try QuickActionFixture.make(in: services, name: "Image Action", types: ["public.image"])
        let file = try scratch.file("Folder/a.png")
        let owner = MainWindowController(urls: [folder]); defer { owner.window?.close() }
        owner.quickActions = FinderQuickActions(directories: [services])
        try #require(await eventually { !owner.view.model.isLoading && owner.view.model.rows.count == 1 })
        owner.view.model.selection = [file]
        let empty = try #require(owner.quickActionMenu(for: nil, in: owner.view))
        try #require(await eventually { empty.items.first?.title == "Folder Action" })
        #expect((empty.items[0].representedObject as? QuickActionInvocation)?.items.map(\.url) == [folder])
        let original = MainWindowController.popUpActionMenu
        defer { MainWindowController.popUpActionMenu = original }
        var toolbar: NSMenu?
        MainWindowController.popUpActionMenu = { menu, _ in toolbar = menu }
        owner.showActionMenu(from: NSView())
        let actions = try #require(toolbar?.items.first { $0.title == "Quick Actions" }?.submenu)
        try #require(await eventually { actions.items.first?.title == "Image Action" })
        #expect((actions.items[0].representedObject as? QuickActionInvocation)?.items.map(\.url) == [file])
    }

    @Test func disablesLineBreakNamesAndOmitsRemoteMenus() async throws {
        let scratch = try Scratch(), services = try scratch.folder("Services")
        try QuickActionFixture.make(in: services)
        let owner = MainWindowController(urls: [scratch.url]); defer { owner.window?.close() }
        owner.quickActions = FinderQuickActions(directories: [services])
        let item = FileItem(url: scratch.path("line\nbreak.txt"), name: "line\nbreak.txt", isDirectory: false)
        let menu = try #require(owner.quickActionMenu(for: item, in: owner.view))
        try #require(await eventually { menu.items.first?.title == "Record" })
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[0].toolTip?.contains("line breaks") == true)
        let remote = FileItem(url: URL(string: "sftp://example.com/a.txt")!, name: "a.txt", isDirectory: false)
        #expect(owner.quickActionMenu(for: remote, in: owner.view) == nil)
    }

    @Test func clickedItemOutsideSelectionReceivesWorkflowErrors() async throws {
        let scratch = try Scratch(), services = try scratch.folder("Services")
        try QuickActionFixture.make(in: services, script: "exit 7")
        let selected = try scratch.file("selected.txt"), clicked = try scratch.file("clicked.txt")
        let owner = MainWindowController(urls: [scratch.url]); defer { owner.window?.close() }
        owner.quickActions = FinderQuickActions(directories: [services])
        owner.view.model.selection = [selected]
        let item = FileItem(url: clicked, name: "clicked.txt", isDirectory: false)
        let menu = try #require(owner.quickActionMenu(for: item, in: owner.view))
        try #require(await eventually { menu.items.first?.title == "Record" })
        let entry = menu.items[0]
        #expect((entry.representedObject as? QuickActionInvocation)?.items.map(\.url) == [clicked])
        owner.runQuickAction(entry)
        try #require(await eventually(30) { !owner.view.messageBar.isHidden })
        #expect(owner.view.messageBar.isError)
        #expect(owner.view.messageBar.text.hasPrefix("Record:"))
    }

    @Test func menuShowsWorkflowIconsAndOpensFinderSettings() async throws {
        let scratch = try Scratch(), services = try scratch.folder("Services")
        try QuickActionFixture.make(in: services, name: "Default")
        try QuickActionFixture.make(in: services, name: "Check", iconName: "NSTouchBarCheck")
        let custom = try QuickActionFixture.make(in: services, name: "Custom", iconName: "CustomTemplate")
        let resources = custom.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 32, height: 16), flipped: false) { bounds in
            NSColor.black.setFill(); bounds.fill(); return true
        }
        try #require(image.tiffRepresentation).write(to: resources.appendingPathComponent("CustomTemplate.tiff"))
        let owner = MainWindowController(urls: [scratch.url]); defer { owner.window?.close() }
        owner.quickActions = FinderQuickActions(directories: [services])
        let menu = try #require(owner.quickActionMenu(for: nil, in: owner.view))
        try #require(await eventually { menu.items.contains { $0.title == "Customize…" } })
        let check = try #require(menu.items.first { $0.title == "Check" }?.image)
        let standard = try #require(menu.items.first { $0.title == "Default" }?.image)
        let customIcon = try #require(menu.items.first { $0.title == "Custom" }?.image)
        #expect(check.size.width == 16)
        #expect(check.size.height < check.size.width)
        #expect(check.size.height > 8)
        #expect(customIcon.size == NSSize(width: 16, height: 8))
        #expect(check.tiffRepresentation != standard.tiffRepresentation)
        #expect(customIcon.isTemplate)
        let original = MainWindowController.openQuickActionsSettings
        defer { MainWindowController.openQuickActionsSettings = original }
        var opened: URL?
        MainWindowController.openQuickActionsSettings = {
            opened = $0; return true
        }
        let index = try #require(menu.items.firstIndex { $0.title == "Customize…" })
        #expect(menu.items[index - 1].isSeparatorItem)
        menu.performActionForItem(at: index)
        #expect(opened?.scheme == "x-apple.systempreferences")
        #expect(opened?.absoluteString.hasSuffix("?extensionPointIdentifier=com.apple.finder-quick-actions") == true)
        MainWindowController.openQuickActionsSettings = { _ in false }
        owner.customizeQuickActions(nil)
        #expect(owner.view.messageBar.text == "Could not open Quick Actions settings.")
    }
}
