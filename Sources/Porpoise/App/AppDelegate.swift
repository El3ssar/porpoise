import AppKit
import PorpoiseCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()
    private(set) var windows: [MainWindowController] = []
    private var settingsWindow: SettingsWindowController?
    /// UserDefaults key of the saved windows/tabs: [[["url": …, "split": …, "mode": …]]].
    private static let sessionKey = "session"

    // MARK: - Launch and quit

    func applicationWillFinishLaunching(_ notification: Notification) {
        // "Show in Finder" requests from other apps, when Dolphin is the default file browser.
        SystemIntegration.installRevealHandlers()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = buildMainMenu()
        NSApp.registerServicesMenuSendTypes([.fileURL], returnTypes: [])
        VideoPreview.shared.cleanUp()
        // Test hook only in test launches (never in normal use).
        if Settings.isTesting { DebugBridge.shared.start() }
        let args = Self.folderArguments()
        // First launch: the onboarding assistant comes first; the browser window opens when it's done.
        if args.isEmpty, windows.isEmpty, OnboardingWindowController.shouldShow {
            OnboardingWindowController.show { [weak self] in self?.openInitialWindows(args) }
        } else {
            openInitialWindows(args)
        }
        Updates.shared.start()
    }

    private func openInitialWindows(_ args: [(folder: URL, select: URL?)]) {
        if !args.isEmpty {
            // A file argument opens its folder with the file selected (Dolphin's --select).
            newWindow(urls: args.map(\.folder))
            if let file = args.first?.select { windows.last?.view.pendingSelect = file }
        } else if !windows.isEmpty {
            // Launched to open folders or reveal files ("Show in Finder" from another app): those windows only.
        } else if Settings.shared.startup == .lastSession, restoreSession() {
            // Restored.
        } else {
            newWindow(at: Settings.shared.homeURL)
        }
        NSApp.activate()
    }

    /// Path arguments: folders open; files open their folder, selected (the first one). Skips "-Key value"
    /// defaults pairs and paths that don't exist.
    private static func folderArguments() -> [(folder: URL, select: URL?)] {
        var out: [(URL, URL?)] = []
        var skipNext = false
        for a in CommandLine.arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if a.hasPrefix("-") { skipNext = !a.hasPrefix("--"); continue }
            let path = (a as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let u = URL(fileURLWithPath: path).standardizedFileURL
            out.append(isDir.boolValue ? (u, nil) : (u.deletingLastPathComponent(), u))
        }
        return out
    }

    /// Reopens the windows and tabs of the last session; false if there was nothing to restore.
    private func restoreSession() -> Bool {
        guard let session = Settings.store.array(forKey: Self.sessionKey) as? [[[String: String]]] else { return false }
        for w in session {
            // Tab and split URLs stay paired when a vanished folder is dropped.
            let tabs = w.compactMap { t -> (url: URL, split: URL?)? in
                guard let u = t["url"].flatMap(URL.init(string:)),
                      !u.isFileURL || FileManager.default.fileExists(atPath: u.path) else { return nil }
                return (u, t["split"].flatMap(URL.init(string:)))
            }
            if !tabs.isEmpty { newWindow(urls: tabs.map(\.url), split: tabs.map(\.split)) }
        }
        return !windows.isEmpty
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Minimized windows are brought back by AppKit; a new one only when there is none.
        if !flag && windows.isEmpty { newWindow(at: Settings.shared.homeURL) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Dolphin asks before quitting with several tabs open.
        if Settings.shared.confirmCloseTabs, windows.contains(where: { $0.tabs.count > 1 }) {
            let a = NSAlert()
            a.messageText = "You have multiple tabs open, are you sure you want to quit?"
            a.addButton(withTitle: "Quit")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Do not ask again"
            let r = a.runModal()
            if a.suppressionButton?.state == .on { Settings.shared.confirmCloseTabs = false }
            if r != .alertFirstButtonReturn { return .terminateCancel }
        }
        // Quitting ends the Terminal panels' shells too (closing the window asks the same).
        if Settings.shared.confirmCloseTerminal,
           let w = windows.first(where: { $0.showTerminal && $0.terminal.hasRunningProgram }) {
            let a = NSAlert()
            a.messageText = "The program “\(w.terminal.runningProgramName)” is still running in the Terminal panel. Are you sure you want to quit?"
            a.addButton(withTitle: "Quit")
            a.addButton(withTitle: "Cancel")
            a.window.appearance = NSAppearance(named: .darkAqua)
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        saveSession()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        VideoPreview.shared.cleanUp()
        RemoteFS.disconnectAll()
        AndroidTools.stopServerIfOurs()
        saveSession()
    }

    /// Starts a new instance once this one has quit (used after granting Full Disk Access).
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Opening folders and revealing files

    /// Shows items selected in their folder (Finder's reveal).
    func reveal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let parent = first.deletingLastPathComponent()
        if let w = windows.first, Settings.shared.singleWindow {
            w.addTab(url: parent)
            w.view.pendingSelect = first
            w.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(at: parent)
            windows.last?.view.pendingSelect = first
        }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Files are revealed in their folder; folders open.
        func isFolder(_ u: URL) -> Bool? {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) ? d.boolValue : nil
        }
        let files = urls.filter { isFolder($0) == false }
        if !files.isEmpty && files.count == urls.count { reveal(files); return }
        let folders = urls.map { isFolder($0) == true ? $0 : $0.deletingLastPathComponent() }
        // "Keep a single Dolphin window, opening new folders in tabs".
        if let w = windows.first, Settings.shared.singleWindow {
            for f in folders { w.addTab(url: f) }
            w.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(urls: folders)
        }
    }

    // MARK: - Windows

    func newWindow(at url: URL, split: URL? = nil) { newWindow(urls: [url], split: [split]) }

    func newWindow(urls: [URL], split: [URL?] = []) {
        let wc = MainWindowController(urls: urls, split: split)
        windows.append(wc)
        // Cascade from the previous window, like document windows.
        if let last = windows.dropLast().last?.window {
            wc.window?.setFrame(last.frame.offsetBy(dx: 24, dy: -24), display: false)
        }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    func windowClosed(_ wc: MainWindowController) {
        windows.removeAll { $0 === wc }
    }

    func saveSession() {
        let state = windows.map(\.sessionState)
        if !state.isEmpty { Settings.store.set(state, forKey: Self.sessionKey) }
    }

    /// Cmd+W in windows without tabs (Settings, Properties…) closes the window, as on any Mac.
    @objc func closeCurrentTab(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    @objc func showPermissions(_ sender: Any?) { OnboardingWindowController.show(at: OnboardingWindowController.firstMissing) }
    @objc func checkForUpdates(_ sender: Any?) { Updates.shared.checkForUpdates(sender) }
    @objc func supportPorpoise(_ sender: Any?) { if let u = URL(string: AppInfo.sponsorPage) { NSWorkspace.shared.open(u) } }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        NSApp.activate()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func configureShortcuts(_ sender: Any?) {
        // macOS manages keyboard shortcuts for app menus centrally.
        if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") { NSWorkspace.shared.open(u) }
    }

    @objc func showHelp(_ sender: Any?) {
        if let u = URL(string: AppInfo.homepage) { NSWorkspace.shared.open(u) }
    }

    // MARK: - Main menu (Dolphin's menu bar, with Ctrl → Cmd)

    private func mi(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                    icon: String? = nil, tag: Int = 0) -> NSMenuItem {
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

    private let sep = { NSMenuItem.separator() }

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
        panels.insertItem(mi("Information", #selector(W.togglePanel(_:)), "i", [.command, .option], icon: "documentinfo", tag: 1).hiddenAlternate(),
                          at: W.panelToggles.count)
        view.addItem(.submenu("Show Panels", icon: "view-sidetree", panels))
        view.addItem(submenu("Location Bar", [
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
        win.addItem(submenu("Go to Tab", (1...9).map { mi("Tab \($0)", #selector(W.activateTab(_:)), "\($0)", .option, tag: $0) }
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
