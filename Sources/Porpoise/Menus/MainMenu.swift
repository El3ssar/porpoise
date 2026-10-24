import AppKit
import PorpoiseCore
import PorpoiseServices

// The main menu: Dolphin's menu bar with Finder's keys, or Dolphin's own (Ctrl → Cmd) with Settings › Shortcuts › Key set.
extension AppDelegate {
    private func mi(
        _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
        icon: String? = nil, tag: Int = 0
    ) -> NSMenuItem {
        .make(title, action, key: key, mods: mods, icon: icon, tag: tag)
    }

    private func submenu(_ title: String, _ items: [NSMenuItem], icon: String? = nil) -> NSMenuItem {
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        return .submenu(title, icon: icon, m)
    }

    /// A submenu filled by `menuNeedsUpdate(_:)` each time it opens (it depends on the active view).
    private func dynamicSubmenu(_ title: String, icon: String) -> NSMenuItem {
        let m = NSMenu(title: title)
        m.delegate = self
        return .submenu(title, icon: icon, m)
    }

    private func sep() -> NSMenuItem { .separator() }

    func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        typealias W = MainWindowController
        typealias K = KeyEquivalent
        // Only the defaults differ; the user's own bindings (MenuCommandRegistry) apply on top of either set.
        let dolphin = Settings.shared.shortcutKeySet == .dolphin

        // App menu
        let app = NSMenu(title: "Porpoise")
        app.addItem(mi("About Porpoise", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(sep())
        app.addItem(mi("Settings…", #selector(showSettings(_:)), ",", icon: "configure"))
        app.addItem(mi("Permissions…", #selector(showPermissions(_:)), icon: "object-locked"))
        app.addItem(mi("Check for Updates…", #selector(checkForUpdates(_:)), icon: "view-refresh"))
        app.addItem(sep())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        app.addItem(.submenu("Services", icon: nil, services))
        app.addItem(sep())
        // ⌘H hides the app, as in every Mac app. Dolphin's keys give it to Show Hidden Files and hide on ⌥⇧⌘H.
        app.addItem(mi("Hide Porpoise", #selector(NSApplication.hide(_:)), "h", dolphin ? [.command, .option, .shift] : .command))
        app.addItem(mi("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(mi("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(sep())
        app.addItem(mi("Quit Porpoise", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(.submenu("Porpoise", icon: nil, app))

        // File
        let file = NSMenu(title: "File")
        file.addItem(.submenu("Create New", icon: "list-add", W.createNewMenu()))
        file.addItem(mi("Open", #selector(W.openSelected(_:)), "o", icon: "document-open"))
        file.addItem(mi("Open", #selector(W.openSelected(_:)), K.down, icon: "document-open").hiddenAlternate())
        // The context menu's Open in… items, on the selected folder (no default keys; assignable in Settings).
        file.addItem(mi("Open in New Tab", #selector(W.ctxOpenInNewTab(_:)), icon: "tab-new"))
        file.addItem(mi("Open in New Window", #selector(W.ctxOpenInNewWindow(_:)), icon: "window-new"))
        file.addItem(mi("Open in Split View", #selector(W.ctxOpenInSplit(_:)), icon: "view-split-left-right"))
        file.addItem(mi("Show Package Contents", #selector(W.showPackageContents(_:)), icon: "folder-open"))
        file.addItem(mi("New Window", #selector(W.newWindow(_:)), "n", icon: "window-new"))
        file.addItem(mi("New Tab", #selector(W.newTab(_:)), "t", icon: "tab-new"))
        file.addItem(mi("Close Tab", #selector(W.closeCurrentTab(_:)), "w", icon: "tab-close"))
        file.addItem(mi("Undo Close Tab", #selector(W.undoCloseTab(_:)), "t", [.command, .shift], icon: "edit-undo"))
        file.addItem(mi("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        file.addItem(sep())
        file.addItem(mi("Add to Places", #selector(W.addToPlaces(_:)), icon: "bookmark-new"))
        file.addItem(sep())
        // Finder's cloud commands (iCloud Drive and connected accounts); no default shortcuts, assignable in Settings.
        file.addItem(mi("Download", #selector(W.cloudDownload(_:))))
        file.addItem(mi("Remove Download", #selector(W.cloudEvict(_:))))
        file.addItem(sep())
        // Return renames, as in Finder (only in the file list, MainWindowActions+Validation); F2 too. Dolphin: F2, Return opens.
        file.addItem(mi("Rename…", #selector(W.renameItem(_:)), dolphin ? K.f(2) : "\r", [], icon: "edit-rename"))
        if !dolphin { file.addItem(mi("Rename…", #selector(W.renameItem(_:)), K.f(2), [], icon: "edit-rename").hiddenAlternate()) }
        file.addItem(mi("Duplicate Here", #selector(W.duplicateItem(_:)), "d", icon: "edit-duplicate"))
        if dolphin {
            // Dolphin's Delete (⌦) trashes and ⇧⌦ deletes; Finder's ⌘⌫ and ⌥⌘⌫ stay as alternates.
            file.addItem(mi("Move to Trash", #selector(W.moveToTrash(_:)), K.forwardDelete, [], icon: "user-trash"))
            file.addItem(mi("Move to Trash", #selector(W.moveToTrash(_:)), K.backspace, .command, icon: "user-trash").hiddenAlternate())
            file.addItem(mi("Delete", #selector(W.deleteItem(_:)), K.forwardDelete, .shift, icon: "edit-delete"))
            file.addItem(
                mi("Delete Immediately", #selector(W.deleteItem(_:)), K.backspace, [.command, .option], icon: "edit-delete").hiddenAlternate())
        } else {
            // Finder's: no key without ⌘ removes anything.
            file.addItem(mi("Move to Trash", #selector(W.moveToTrash(_:)), K.backspace, .command, icon: "user-trash"))
            file.addItem(mi("Delete Immediately…", #selector(W.deleteItem(_:)), K.backspace, [.command, .option], icon: "edit-delete"))
        }
        file.addItem(mi("Restore from Trash", #selector(W.restoreFromTrash(_:)), icon: "restoration"))
        file.addItem(mi("Make Alias", #selector(W.makeAlias(_:)), "a", [.command, .control], icon: "insert-link"))
        file.addItem(mi("Show Original", #selector(W.showOriginal(_:)), "r", icon: "document-open-folder"))
        file.addItem(mi("New Folder with Selection", #selector(W.newFolderWithSelection(_:)), "n", [.command, .control], icon: "folder-new"))
        file.addItem(mi("Eject", #selector(W.ejectVolume(_:)), "e", icon: "media-eject"))
        file.addItem(sep())
        file.addItem(mi("Save Changes", #selector(FileDiffWindow.saveDocument(_:)), "s", icon: "media-floppy"))
        file.addItem(mi("Compare Files…", #selector(W.compareFiles(_:)), "y", [.command, .option], icon: "document-preview"))
        file.addItem(mi("Quick Look", #selector(W.quickLook(_:)), "y", icon: "document-preview"))
        file.addItem(mi("Share…", #selector(W.shareItems(_:)), icon: "document-share"))
        file.addItem(mi("AirDrop…", #selector(W.airDropItems(_:)), icon: "airdrop"))
        file.addItem(mi("Get Info", #selector(W.properties(_:)), dolphin ? "\r" : "i", dolphin ? .option : .command, icon: "document-properties"))
        file.addItem(dynamicSubmenu("Tags", icon: "tag"))
        main.addItem(.submenu("File", icon: nil, file))

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(mi("Undo", #selector(W.undoFileOperation(_:)), "z", icon: "edit-undo"))
        edit.addItem(mi("Redo", #selector(W.redoFileOperation(_:)), "z", [.command, .shift], icon: "edit-redo"))
        edit.addItem(sep())
        edit.addItem(mi("Command Palette…", #selector(showCommandPalette(_:)), "p", [.command, .shift], icon: "system-search"))
        edit.addItem(mi("Command Palette…", #selector(showCommandPalette(_:)), "i", [.control, .option], icon: "system-search").hiddenAlternate())
        edit.addItem(sep())
        edit.addItem(mi("Cut", #selector(W.cut(_:)), "x", icon: "edit-cut"))
        edit.addItem(mi("Copy", #selector(W.copy(_:)), "c", icon: "edit-copy"))
        edit.addItem(mi("Copy Location", #selector(W.copyLocation(_:)), "c", [.command, .option], icon: "link"))
        edit.addItem(mi("Add to Shelf", #selector(W.addToShelf(_:)), "s", [.command, .option], icon: "bookmarks"))
        edit.addItem(mi("Paste", #selector(W.paste(_:)), "v", icon: "edit-paste"))
        edit.addItem(sep())
        edit.addItem(
            mi("Filter…", #selector(W.showFilterBar(_:)), dolphin ? "i" : "f", dolphin ? .command : [.command, .option], icon: "view-filter"))
        edit.addItem(mi("Search…", #selector(W.showSearch(_:)), "f", icon: "edit-find"))
        edit.addItem(sep())
        edit.addItem(mi("Select Files and Folders", #selector(W.toggleSelectionMode(_:)), " ", [.command, .shift], icon: "edit-select"))
        edit.addItem(mi("Copy to Other View", #selector(W.copyToOtherView(_:)), K.f(5), .shift, icon: "edit-copy"))
        edit.addItem(mi("Move to Other View", #selector(W.moveToOtherView(_:)), K.f(6), .shift, icon: "edit-move"))
        edit.addItem(mi("Select All", #selector(NSResponder.selectAll(_:)), "a", icon: "edit-select-all"))
        edit.addItem(mi("Deselect All", #selector(W.deselectAll(_:)), "a", [.command, .option], icon: "edit-select"))
        edit.addItem(mi("Invert Selection", #selector(W.invertSelection(_:)), "a", [.command, .option, .shift], icon: "edit-select-invert"))
        edit.addItem(mi("Select Matching…", #selector(W.selectMatching(_:)), "s", [.command, .shift], icon: "edit-select"))
        edit.addItem(mi("Deselect Matching…", #selector(W.deselectMatching(_:)), "s", [.command, .option, .shift], icon: "edit-select"))
        main.addItem(.submenu("Edit", icon: nil, edit))

        // View
        let view = NSMenu(title: "View")
        view.addItem(mi("Zoom In", #selector(W.zoomIn(_:)), "+", icon: "zoom-in"))
        view.addItem(mi("Zoom In", #selector(W.zoomIn(_:)), "=", icon: "zoom-in").hiddenAlternate())
        view.addItem(mi("Reset Zoom Level", #selector(W.zoomReset(_:)), "0", icon: "zoom-original"))
        view.addItem(mi("Zoom Out", #selector(W.zoomOut(_:)), "-", icon: "zoom-out"))
        view.addItem(sep())
        view.addItem(dynamicSubmenu("Sort By", icon: "view-sort"))
        view.addItem(dynamicSubmenu("Group By", icon: "view-group"))
        view.addItem(.submenu("View Mode", icon: "view-list-icons", W.viewModeMenu()))
        view.addItem(dynamicSubmenu("Show Additional Information", icon: "documentinfo"))
        view.addItem(mi("Show Previews", #selector(W.togglePreviews(_:)), K.f(12), [], icon: "view-preview"))
        if dolphin {
            view.addItem(mi("Show Hidden Files", #selector(W.toggleHiddenFiles(_:)), "h", icon: "view-hidden"))
            view.addItem(mi("Show Hidden Files", #selector(W.toggleHiddenFiles(_:)), ".", [.command, .shift], icon: "view-hidden").hiddenAlternate())
        } else {
            view.addItem(mi("Show Hidden Files", #selector(W.toggleHiddenFiles(_:)), ".", [.command, .shift], icon: "view-hidden"))
        }
        view.addItem(sep())
        view.addItem(mi("Restore to Defaults", #selector(W.restoreViewDefaults(_:)), icon: "edit-undo"))
        view.addItem(mi("Adjust View Display Style…", #selector(W.adjustViewStyle(_:)), "j", icon: "configure"))
        view.addItem(sep())
        view.addItem(mi("Linked Browsing", #selector(W.toggleLinkedBrowsing(_:)), "l", [.command, .control], icon: "insert-link"))
        view.addItem(mi("Split", #selector(W.toggleSplit(_:)), K.f(3), [], icon: "view-split-left-right"))
        view.addItem(mi("Split View to Tabs", #selector(W.splitToTabs(_:)), K.f(3), [.command, .shift], icon: "tab-new"))
        view.addItem(mi("Pop out Split View", #selector(W.popOutSplit(_:)), K.f(3), .shift, icon: "window-new"))
        view.addItem(mi("Focus Other View", #selector(W.focusOtherView(_:)), K.f(3), .command))
        view.addItem(mi("Focus Left View", #selector(W.focusLeftPane(_:)), K.left, .option))
        view.addItem(mi("Focus Right View", #selector(W.focusRightPane(_:)), K.right, .option))
        view.addItem(mi("Reload", #selector(W.reloadView(_:)), K.f(5), [], icon: "view-refresh"))
        view.addItem(sep())
        let panels = W.panelsMenu()
        // F10 (macOS reserves F11 for Show Desktop); Cmd+Opt+I (Finder's inspector key) also toggles Information.
        panels.insertItem(
            mi("Information", #selector(W.togglePanel(_:)), "i", [.command, .option], icon: "documentinfo", tag: 1).hiddenAlternate(),
            at: W.panelToggles.count)
        view.addItem(.submenu("Show Panels", icon: "view-sidetree", panels))
        view.addItem(
            submenu(
                "Location Bar",
                [
                    mi("Editable Location", #selector(W.editLocation(_:)), K.f(6), []),
                    mi("Replace Location", #selector(W.replaceLocation(_:)), "l"),
                ]))
        view.addItem(sep())
        view.addItem(mi("Customize Toolbar…", #selector(customizeToolbar(_:)), icon: "configure"))
        view.addItem(mi("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        main.addItem(.submenu("View", icon: nil, view))

        // Go
        let go = NSMenu(title: "Go")
        go.addItem(sep())
        go.addItem(mi("Up", #selector(W.goUp(_:)), K.up, .option, icon: "go-up"))
        go.addItem(mi("Up", #selector(W.goUp(_:)), K.up, .command, icon: "go-up").hiddenAlternate())
        // Back/Forward on ⌘[ / ⌘] like Finder, and on ⌘← / ⌘→ (⌫ also goes back); ⌥← / ⌥→ switch split panes.
        go.addItem(mi("Back", #selector(W.goBack(_:)), "[", .command, icon: "go-previous"))
        go.addItem(mi("Back", #selector(W.goBack(_:)), K.left, .command, icon: "go-previous").hiddenAlternate())
        go.addItem(mi("Forward", #selector(W.goForward(_:)), "]", .command, icon: "go-next"))
        go.addItem(mi("Forward", #selector(W.goForward(_:)), K.right, .command, icon: "go-next").hiddenAlternate())
        go.addItem(mi("Home", #selector(W.goHome(_:)), K.home, .option, icon: "go-home"))
        go.addItem(mi("Home", #selector(W.goHome(_:)), "h", [.command, .shift], icon: "go-home").hiddenAlternate())
        for (i, t) in W.goTargets.enumerated() { go.addItem(mi(t.title, #selector(W.goToTarget(_:)), t.key, t.mods, icon: t.icon, tag: i)) }
        go.addItem(mi("AirDrop", #selector(W.goAirDrop(_:)), "r", [.command, .shift], icon: "airdrop"))
        go.addItem(mi("Network", #selector(W.goNetwork(_:)), "k", [.command, .shift], icon: "network-workgroup"))
        go.addItem(sep())
        go.addItem(mi("Go to Folder…", #selector(W.goToFolder(_:)), "g", [.command, .shift], icon: "document-open-folder"))
        go.addItem(mi("Connect to Server…", #selector(W.connectToServer(_:)), "k", icon: "folder-network"))
        go.addItem(mi("Connections…", #selector(W.showConnections(_:)), "k", [.command, .option], icon: "network-server"))
        go.addItem(sep())
        go.addItem(dynamicSubmenu("Places", icon: "compass"))
        main.addItem(.submenu("Go", icon: nil, go))

        // Tools
        let tools = NSMenu(title: "Tools")
        tools.addItem(mi("Open Terminal", #selector(W.openTerminal(_:)), K.f(4), .shift, icon: "utilities-terminal"))
        tools.addItem(mi("Open Terminal Here", #selector(W.openTerminalHere(_:)), K.f(4), [.shift, .option], icon: "utilities-terminal"))
        tools.addItem(mi("Reveal in Finder", #selector(W.revealInFinder(_:)), "r", [.command, .option], icon: "document-open-folder"))
        tools.addItem(mi("Checksums…", #selector(W.showChecksums(_:)), icon: "documentinfo"))
        tools.addItem(mi("Disk Usage…", #selector(W.showDiskUsage(_:)), icon: "drive-harddisk"))
        tools.addItem(mi("Find Duplicates…", #selector(W.showDuplicates(_:)), icon: "edit-copy"))
        tools.addItem(mi("Compress", #selector(W.compress(_:)), icon: "archive-insert"))
        tools.addItem(mi("Extract Here", #selector(W.extractHere(_:)), icon: "archive-extract"))
        tools.addItem(mi("Remove App and Leftovers…", #selector(W.removeAppAndLeftovers(_:)), icon: "trash-empty"))
        tools.addItem(mi("Empty Trash", #selector(W.emptyTrash(_:)), K.backspace, [.command, .shift], icon: "trash-empty"))
        tools.addItem(.separator())
        for tool in Settings.shared.customToolsIfLoaded {
            let item = NSMenuItem(title: tool.name, action: #selector(W.runCustomTool(_:)), keyEquivalent: tool.shortcut.normalized.key)
            item.keyEquivalentModifierMask = tool.shortcut.normalized.modifiers.appKit
            item.representedObject = tool.id.uuidString
            tools.addItem(item)
        }
        tools.addItem(mi("Configure Custom Tools…", #selector(W.showCustomTools(_:))))
        main.addItem(.submenu("Tools", icon: nil, tools))

        // Window
        let win = NSMenu(title: "Window")
        win.addItem(mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(mi("Zoom", #selector(NSWindow.performZoom(_:))))
        win.addItem(sep())
        win.addItem(mi("Activity", #selector(AppDelegate.showActivity(_:)), "j", [.command, .option]))
        win.addItem(sep())
        win.addItem(mi("Next Tab", #selector(W.nextTab(_:)), "\t", .control))
        win.addItem(mi("Previous Tab", #selector(W.previousTab(_:)), "\t", [.control, .shift]))
        win.addItem(mi("Next Tab", #selector(W.nextTab(_:)), "}", .command).hiddenAlternate())
        win.addItem(mi("Previous Tab", #selector(W.previousTab(_:)), "{", .command).hiddenAlternate())
        win.addItem(mi("Next Tab", #selector(W.nextTab(_:)), K.pageDown, .command).hiddenAlternate())
        win.addItem(mi("Previous Tab", #selector(W.previousTab(_:)), K.pageUp, .command).hiddenAlternate())
        win.addItem(
            submenu(
                "Go to Tab",
                (1...9).map { mi("Tab \($0)", #selector(W.activateTab(_:)), "\($0)", .option, tag: $0) }
                    + [mi("Last Tab", #selector(W.activateTab(_:)), "0", .option, tag: 0)]))
        win.addItem(sep())
        win.addItem(dynamicSubmenu("Workspaces", icon: "view-group"))
        win.addItem(mi("Save Workspace…", #selector(W.saveWorkspace(_:)), "s", [.command, .control], icon: "bookmark-new"))
        win.addItem(sep())
        win.addItem(mi("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = win
        main.addItem(.submenu("Window", icon: nil, win))

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(mi("Keyboard Shortcuts", #selector(showKeyboardShortcuts(_:)), "?", icon: "input-keyboard"))
        help.addItem(mi("Install Guide", #selector(showInstallGuide(_:)), icon: "package-install"))
        let capabilities = NSMenu(title: "Location Capabilities")
        for location in ProviderLocation.allCases {
            let item = mi(location.title, #selector(showLocationCapabilities(_:)))
            item.representedObject = location.rawValue
            capabilities.addItem(item)
        }
        help.addItem(.submenu("Location Capabilities", icon: "help-contents", capabilities))
        help.addItem(mi("Report a Bug…", #selector(reportBug(_:)), icon: "emblem-warning"))
        help.addItem(sep())
        help.addItem(mi("Porpoise Website", #selector(showHelp(_:)), icon: "help-contents"))
        help.addItem(mi("Export Diagnostics…", #selector(exportDiagnostics(_:)), icon: "document-share"))
        help.addItem(mi("Support Porpoise (Donate)…", #selector(supportPorpoise(_:)), icon: "emblem-favorite"))
        NSApp.helpMenu = help
        main.addItem(.submenu("Help", icon: nil, help))
        return main
    }

    /// Copy of the menu bar for the hamburger's "More" submenu.
    func mainMenuCopy() -> NSMenu {
        let m = NSMenu()
        guard let main = NSApp.mainMenu else { return m }
        for it in main.items.dropFirst() where it.title != "Window" && it.title != "Help" {
            let c = NSMenuItem(title: it.title, action: nil, keyEquivalent: "")
            if let original = it.submenu, let copy = original.copy() as? NSMenu {
                Self.copyDelegates(from: original, to: copy)
                c.submenu = copy
            }
            m.addItem(c)
        }
        return m
    }

    /// NSMenu's copy drops delegates, which would leave the dynamic submenus (Sort By, Places…) empty.
    private static func copyDelegates(from original: NSMenu, to copy: NSMenu) {
        copy.delegate = original.delegate
        for (o, c) in zip(original.items, copy.items) {
            if let os = o.submenu, let cs = c.submenu { copyDelegates(from: os, to: cs) }
        }
    }

    /// Fills the dynamic submenus (they need the active window's view state).
    @MainActor func menuNeedsUpdate(_ menu: NSMenu) {
        guard let wc = NSApp.keyWindow?.windowController as? MainWindowController ?? windows.first else { return }
        let built: NSMenu
        switch menu.title {
        case "Sort By": built = wc.sortMenu()
        case "Group By": built = wc.groupMenu()
        case "Show Additional Information": built = wc.additionalInfoMenu()
        case "Workspaces": built = wc.workspacesMenu()
        case "Tags": built = wc.tagsMenu(for: wc.view.model.selectedItems.filter { $0.url.isFileURL })
        case "Places":
            built = NSMenu()
            for e in PlacesModel.shared.allEntries where !e.hidden {
                built.addItem(.make(e.title, #selector(MainWindowController.goToPlace(_:)), mods: [], icon: e.icon, obj: e.url.absoluteString))
            }
        default: return
        }
        menu.removeAllItems()
        for it in built.items { built.removeItem(it); menu.addItem(it) }
        MenuCommandRegistry.shared.apply(to: menu)
    }
}
