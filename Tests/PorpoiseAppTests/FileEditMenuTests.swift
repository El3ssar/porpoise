import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// P11 (ux #17, #18): the File and Edit menus in Finder's order, and File items for other places hidden until they apply.
@MainActor @Suite(.serialized, .isolatedSettings) struct FileEditMenuTests {
    private typealias W = MainWindowController
    init() { _ = NSApplication.shared }

    private func menus(_ keySet: ShortcutKeySet) throws -> (file: NSMenu, edit: NSMenu) {
        Settings.shared.shortcutKeySet = keySet
        let bar = AppDelegate.shared.buildMainMenu()
        NSApp.mainMenu = bar
        MenuCommandRegistry.shared.refresh(fillDynamic: false)
        return (
            try #require(bar.items.first { $0.title == "File" }?.submenu), try #require(bar.items.first { $0.title == "Edit" }?.submenu)
        )
    }
    private func visible(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "---" : $0.title } }

    @Test(arguments: ShortcutKeySet.allCases) func fileMenuStartsWithNewThings(_ keySet: ShortcutKeySet) throws {
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous; MenuCommandRegistry.shared.refresh(fillDynamic: false) }
        let (file, _) = try menus(keySet)
        #expect(Array(visible(file).prefix(5)) == ["New Window", "New Folder…", "New Tab", "Create New", "New Folder with Selection"])
        let newFolder = try #require(file.items.first { $0.action == #selector(W.createFolder(_:)) })
        #expect(newFolder.keyEquivalent == "n" && newFolder.keyEquivalentModifierMask == [.command, .shift])
        // Create New › Folder… would repeat it: the submenu starts with the file kinds.
        let createNew = try #require(file.items.first { $0.title == "Create New" }?.submenu)
        #expect(!createNew.items.contains { $0.action == #selector(W.createFolder(_:)) })
        #expect(visible(file).last == "Tags" && visible(file).contains("Eject"))
        // Same keys as before the reorder: one command per key.
        #expect(MenuCommandRegistry.shared.shortcut(for: #selector(W.createFolder(_:))) == KeyboardShortcut(key: "n", modifiers: [.command, .shift]))
    }

    /// Outside a cloud folder and with no Compare Files window in front, Download, Remove Download and Save Changes are
    /// hidden, and Save Changes keeps ⌘S for when it applies.
    @Test func fileItemsForOtherPlacesAreHidden() async throws {
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous; MenuCommandRegistry.shared.refresh(fillDynamic: false) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let (file, _) = try menus(.mac)
        let s = try Scratch()
        let doc = try s.file("doc.txt", "x")
        AppDelegate.shared.newWindow(at: s.url)
        let wc = try #require(AppDelegate.shared.windows.last)
        defer { wc.window?.close() }
        try #require(await eventually { !wc.view.model.isLoading })
        file.delegate?.menuNeedsUpdate?(file)
        for action in [#selector(W.cloudDownload(_:)), #selector(W.cloudEvict(_:)), #selector(FileDiffWindow.saveDocument(_:))] {
            let item = try #require(file.items.first { $0.action == action })
            #expect(item.isHidden && item.allowsKeyEquivalentWhenHidden, "\(action)")
        }
        let save = try #require(file.items.first { $0.action == #selector(FileDiffWindow.saveDocument(_:)) })
        #expect(save.keyEquivalent == "s" && save.keyEquivalentModifierMask == .command)
        #expect(visible(file).contains("Compare Files…") && !visible(file).contains("Save Changes"))

        // iCloud Drive and File Provider items are file URLs: their folder or selection shows the cloud commands.
        let saved = W.cloudState
        defer { W.cloudState = saved }
        let cloudItems: (DirectoryModel, FileItem) -> (state: CloudState, isCloud: Bool) = { model, item in
            item.url.standardizedFileURL == doc.standardizedFileURL ? (.local, true) : model.cloud(for: item)
        }
        W.cloudState = cloudItems
        wc.view.list.select(doc)
        file.delegate?.menuNeedsUpdate?(file)
        let download = try #require(file.items.first { $0.action == #selector(W.cloudDownload(_:)) })
        let remove = try #require(file.items.first { $0.action == #selector(W.cloudEvict(_:)) })
        #expect(!download.isHidden && !remove.isHidden)
        #expect(wc.validateMenuItem(remove))  // a downloaded iCloud file: Remove Download applies
        // The folder itself in iCloud Drive: shown with nothing selected.
        W.cloudState = { model, item in item.url.standardizedFileURL == s.url.standardizedFileURL ? (.local, true) : cloudItems(model, item) }
        wc.view.model.selection = []
        file.delegate?.menuNeedsUpdate?(file)
        #expect(!download.isHidden)
        // Back in a plain folder with a plain selection: hidden again.
        W.cloudState = saved
        wc.view.list.select(doc)
        file.delegate?.menuNeedsUpdate?(file)
        #expect(download.isHidden && remove.isHidden)
    }

    @Test func editMenuInFinderOrder() throws {
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous; MenuCommandRegistry.shared.refresh(fillDynamic: false) }
        let (_, edit) = try menus(.mac)
        let shown = visible(edit)
        #expect(Array(shown.prefix(7)) == ["Undo", "Redo", "---", "Cut", "Copy", "Copy Location", "Paste"])
        let palette = try #require(shown.firstIndex(of: "Command Palette…"))
        for title in ["Select All", "Invert Selection", "Copy to Other View", "Add to Shelf", "Filter…", "Search…"] {
            #expect((shown.firstIndex(of: title) ?? .max) < palette, "\(title)")
        }
    }

    /// Empty space: New Folder… first, and Create New without a second Folder….
    @Test func emptySpaceCreateNewHasNoSecondFolder() async throws {
        let s = try Scratch()
        let owner = W(urls: [s.url])
        defer { owner.window?.close() }
        owner.showWindow(nil)
        try #require(await eventually { !owner.view.model.isLoading })
        let menu = owner.contextMenu(for: nil, in: owner.view)
        let createNew = try #require(menu.items.first { $0.title == "Create New" }?.submenu)
        #expect(menu.items.first?.action == #selector(W.createFolder(_:)))
        #expect(!createNew.items.contains { $0.action == #selector(W.createFolder(_:)) })
    }
}
