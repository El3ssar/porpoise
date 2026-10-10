import AppKit
import PorpoiseCore
import PorpoiseServices

// The main menu: Dolphin's menu bar, with Ctrl → Cmd.
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

        // App menu
        let app = NSMenu(title: "Porpoise")
        app.addItem(mi("About Porpoise", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(sep())
        app.addItem(mi("Settings…", #selector(showSettings(_:)), ",", icon: "configure"))
        app.addItem(mi("Permissions…", #selector(showPermissions(_:)), icon: "security-high"))
        app.addItem(mi("Check for Updates…", #selector(checkForUpdates(_:)), icon: "update-none"))
        app.addItem(sep())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        app.addItem(.submenu("Services", icon: nil, services))
        app.addItem(sep())
        // Cmd+H is "Show Hidden Files" (Dolphin's Ctrl+H); hiding the app moves to Cmd+Opt+Shift+H.
        app.addItem(mi("Hide Porpoise", #selector(NSApplication.hide(_:)), "h", [.command, .option, .shift]))
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
        file.addItem(mi("New Window", #selector(W.newWindow(_:)), "n", icon: "window-new"))
        file.addItem(mi("New Tab", #selector(W.newTab(_:)), "t", icon: "tab-new"))
        file.addItem(mi("Close Tab", #selector(W.closeCurrentTab(_:)), "w", icon: "tab-close"))
        file.addItem(mi("Undo Close Tab", #selector(W.undoCloseTab(_:)), "t", [.command, .shift], icon: "edit-undo"))
        file.addItem(mi("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        file.addItem(sep())
        file.addItem(mi("Add to Places", #selector(W.addToPlaces(_:)), icon: "bookmark-new"))
        file.addItem(sep())
        file.addItem(mi("Rename…", #selector(W.renameItem(_:)), K.f(2), [], icon: "edit-rename"))
        file.addItem(mi("Duplicate Here", #selector(W.duplicateItem(_:)), "d", icon: "edit-duplicate"))
        file.addItem(mi("Move to Trash", #selector(W.moveToTrash(_:)), K.forwardDelete, [], icon: "user-trash"))
        file.addItem(mi("Move to Trash", #selector(W.moveToTrash(_:)), K.backspace, .command, icon: "user-trash").hiddenAlternate())
        file.addItem(mi("Delete", #selector(W.deleteItem(_:)), K.forwardDelete, .shift, icon: "edit-delete"))
        file.addItem(mi("Delete Immediately", #selector(W.deleteItem(_:)), K.backspace, [.command, .option], icon: "edit-delete").hiddenAlternate())
        file.addItem(mi("Make Alias", #selector(W.makeAlias(_:)), "a", [.command, .control], icon: "insert-link"))
        file.addItem(mi("Show Original", #selector(W.showOriginal(_:)), "r", icon: "document-open-folder"))
        file.addItem(mi("New Folder with Selection", #selector(W.newFolderWithSelection(_:)), "n", [.command, .control], icon: "folder-new"))
        file.addItem(mi("Eject", #selector(W.ejectVolume(_:)), "e", icon: "media-eject"))
        file.addItem(sep())
        file.addItem(mi("Quick Look", #selector(W.quickLook(_:)), "y", icon: "document-preview"))
        file.addItem(mi("Share…", #selector(W.shareItems(_:)), icon: "document-share"))
        file.addItem(mi("Properties", #selector(W.properties(_:)), "\r", .option, icon: "document-properties"))
        main.addItem(.submenu("File", icon: nil, file))

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(mi("Undo", #selector(W.undoFileOperation(_:)), "z", icon: "edit-undo"))
        edit.addItem(mi("Redo", #selector(W.redoFileOperation(_:)), "z", [.command, .shift], icon: "edit-redo"))
        edit.addItem(sep())
        edit.addItem(mi("Cut", #selector(W.cut(_:)), "x", icon: "edit-cut"))
        edit.addItem(mi("Copy", #selector(W.copy(_:)), "c", icon: "edit-copy"))
        edit.addItem(mi("Copy Location", #selector(W.copyLocation(_:)), "c", [.command, .option], icon: "edit-copy-path"))
        edit.addItem(mi("Paste", #selector(W.paste(_:)), "v", icon: "edit-paste"))
        edit.addItem(sep())
        edit.addItem(mi("Filter…", #selector(W.showFilterBar(_:)), "i", icon: "view-filter"))
        edit.addItem(mi("Search…", #selector(W.showSearch(_:)), "f", icon: "edit-find"))
        edit.addItem(sep())
        edit.addItem(mi("Select Files and Folders", #selector(W.toggleSelectionMode(_:)), " ", [.command, .shift], icon: "edit-select"))
        edit.addItem(mi("Copy to Other View", #selector(W.copyToOtherView(_:)), K.f(5), .shift, icon: "edit-copy"))
        edit.addItem(mi("Move to Other View", #selector(W.moveToOtherView(_:)), K.f(6), .shift, icon: "edit-move"))
        edit.addItem(mi("Select All", #selector(NSResponder.selectAll(_:)), "a", icon: "edit-select-all"))
        edit.addItem(mi("Deselect All", #selector(W.deselectAll(_:)), "a", [.command, .option], icon: "edit-select-none"))
        edit.addItem(mi("Invert Selection", #selector(W.invertSelection(_:)), "a", [.command, .option, .shift], icon: "edit-select-invert"))
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
        view.addItem(mi("Show Hidden Files", #selector(W.toggleHiddenFiles(_:)), "h", icon: "view-hidden"))
        view.addItem(mi("Show Hidden Files", #selector(W.toggleHiddenFiles(_:)), ".", [.command, .shift], icon: "view-hidden").hiddenAlternate())
        view.addItem(sep())
        view.addItem(mi("Restore to Defaults", #selector(W.restoreViewDefaults(_:)), icon: "edit-reset"))
        view.addItem(mi("Adjust View Display Style…", #selector(W.adjustViewStyle(_:)), "j", icon: "configure"))
        view.addItem(sep())
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
        view.addItem(mi("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        main.addItem(.submenu("View", icon: nil, view))

        // Go
        let go = NSMenu(title: "Go")
        go.addItem(mi("Up", #selector(W.goUp(_:)), K.up, .option, icon: "go-up"))
        go.addItem(mi("Up", #selector(W.goUp(_:)), K.up, .command, icon: "go-up").hiddenAlternate())
        // Back/Forward on ⌘[ / ⌘] like Finder (⌫ also goes back); ⌥← / ⌥→ switch split panes.
        go.addItem(mi("Back", #selector(W.goBack(_:)), "[", .command, icon: "go-previous"))
        go.addItem(mi("Forward", #selector(W.goForward(_:)), "]", .command, icon: "go-next"))
        go.addItem(mi("Home", #selector(W.goHome(_:)), K.home, .option, icon: "go-home"))
        go.addItem(mi("Home", #selector(W.goHome(_:)), "h", [.command, .shift], icon: "go-home").hiddenAlternate())
        for (i, t) in W.goTargets.enumerated() { go.addItem(mi(t.title, #selector(W.goToTarget(_:)), t.key, t.mods, icon: t.icon, tag: i)) }
        go.addItem(mi("AirDrop", #selector(W.goAirDrop(_:)), "r", [.command, .shift], icon: "network-wireless"))
        go.addItem(mi("Network", #selector(W.goNetwork(_:)), "k", [.command, .shift], icon: "network-workgroup"))
        go.addItem(sep())
        go.addItem(mi("Go to Folder…", #selector(W.goToFolder(_:)), "g", [.command, .shift], icon: "document-open-folder"))
        go.addItem(mi("Connect to Server…", #selector(W.connectToServer(_:)), "k", icon: "folder-network"))
        go.addItem(sep())
        go.addItem(dynamicSubmenu("Places", icon: "compass"))
        main.addItem(.submenu("Go", icon: nil, go))

        // Tools
        let tools = NSMenu(title: "Tools")
        tools.addItem(mi("Open Terminal", #selector(W.openTerminal(_:)), K.f(4), .shift, icon: "utilities-terminal"))
        tools.addItem(mi("Open Terminal Here", #selector(W.openTerminalHere(_:)), K.f(4), [.shift, .option], icon: "utilities-terminal"))
        tools.addItem(mi("Reveal in Finder", #selector(W.revealInFinder(_:)), "r", [.command, .option], icon: "system-file-manager"))
        tools.addItem(mi("Compress", #selector(W.compress(_:)), icon: "archive-insert"))
        tools.addItem(mi("Empty Trash", #selector(W.emptyTrash(_:)), K.backspace, [.command, .shift], icon: "trash-empty"))
        main.addItem(.submenu("Tools", icon: nil, tools))

        // Window
        let win = NSMenu(title: "Window")
        win.addItem(mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(mi("Zoom", #selector(NSWindow.performZoom(_:))))
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
        win.addItem(mi("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = win
        main.addItem(.submenu("Window", icon: nil, win))

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(mi("Porpoise Help", #selector(showHelp(_:)), "?", icon: "help-contents"))
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
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let wc = NSApp.keyWindow?.windowController as? MainWindowController ?? windows.first else { return }
        let built: NSMenu
        switch menu.title {
        case "Sort By": built = wc.sortMenu()
        case "Group By": built = wc.groupMenu()
        case "Show Additional Information": built = wc.additionalInfoMenu()
        case "Places":
            built = NSMenu()
            for e in PlacesModel.shared.allEntries where !e.hidden {
                built.addItem(.make(e.title, #selector(MainWindowController.goToPlace(_:)), mods: [], icon: e.icon, obj: e.url.absoluteString))
            }
        default: return
        }
        menu.removeAllItems()
        for it in built.items { built.removeItem(it); menu.addItem(it) }
    }
}
