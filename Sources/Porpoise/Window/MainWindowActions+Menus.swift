import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Menus built from actions (hamburger, view settings, menu bar submenus)

extension MainWindowController {

    /// The panels in the order of `togglePanel(_:)`'s tags: title, function key, icon.
    static let panelToggles: [(title: String, fkey: Int, icon: String)] = [
        ("Places", 9, "compass"), ("Information", 10, "documentinfo"), ("Folders", 7, "folder"), ("Terminal", 4, "dialog-scripts"),
    ]

    func item(
        _ title: String, _ icon: String?, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = .command,
        tag: Int = 0, obj: Any? = nil
    ) -> NSMenuItem {
        .make(title, action, key: key, mods: mods, icon: icon, tag: tag, obj: obj)
    }

    func sub(_ title: String, _ icon: String?, _ menu: NSMenu) -> NSMenuItem { .submenu(title, icon: icon, menu) }

    func sortMenu() -> NSMenu {
        let m = NSMenu(title: "Sort By")
        for role in ItemRole.menuRoles where role != .tags {
            m.addItem(item(role.title, nil, #selector(sortBy(_:)), obj: role.rawValue))
        }
        let other = NSMenu()
        for role in ItemRole.otherRoles { other.addItem(item(role.title, nil, #selector(sortBy(_:)), obj: role.rawValue)) }
        m.addItem(sub("Other", nil, other))
        m.addItem(.separator())
        m.addItem(item("A-Z", "view-sort-ascending", #selector(setSortAscending(_:))))
        m.addItem(item("Z-A", "view-sort-descending", #selector(setSortDescending(_:))))
        m.addItem(.separator())
        m.addItem(item("Folders First", nil, #selector(toggleFoldersFirst(_:))))
        m.addItem(item("Hidden Files Last", nil, #selector(toggleHiddenLast(_:))))
        return m
    }

    func groupMenu() -> NSMenu {
        let m = NSMenu(title: "Group By")
        m.addItem(item("None", nil, #selector(groupBy(_:))))
        m.addItem(item("Same as Sort", nil, #selector(groupBy(_:)), obj: "same"))
        m.addItem(.separator())
        for role in ItemRole.menuRoles where role != .tags { m.addItem(item(role.title, nil, #selector(groupBy(_:)), obj: role.rawValue)) }
        return m
    }

    func additionalInfoMenu() -> NSMenu {
        let m = NSMenu(title: "Show Additional Information")
        for role in ItemRole.menuRoles where role != .name {
            m.addItem(item(role.title, nil, #selector(toggleAdditionalRole(_:)), obj: role.rawValue))
        }
        let other = NSMenu()
        for role in ItemRole.otherRoles { other.addItem(item(role.title, nil, #selector(toggleAdditionalRole(_:)), obj: role.rawValue)) }
        m.addItem(sub("Other", nil, other))
        return m
    }

    /// Icons / Compact / Details on ⌘1…⌘3.
    static func viewModeItems() -> [NSMenuItem] {
        ViewMode.allCases.enumerated().map { i, m in
            .make(m.title, #selector(setViewMode(_:)), key: "\(i + 1)", icon: m.iconName, tag: i)
        }
    }

    static func viewModeMenu() -> NSMenu {
        let m = NSMenu(title: "View Mode")
        viewModeItems().forEach(m.addItem)
        return m
    }

    /// The toolbar "View Settings" dropdown (Dolphin 24.02+).
    func viewSettingsMenu() -> NSMenu {
        let m = NSMenu()
        Self.viewModeItems().forEach(m.addItem)
        m.addItem(.separator())
        let zoomItem = NSMenuItem()
        zoomItem.view = ZoomSliderMenuView(level: view.model.props.zoomLevel(for: view.model.props.mode)) { [weak self] l in self?.view.setZoom(l) }
        m.addItem(zoomItem)
        m.addItem(.separator())
        m.addItem(sub("Sort By", "view-sort", sortMenu()))
        m.addItem(sub("Group By", "view-group", groupMenu()))
        m.addItem(sub("Show Additional Information", "documentinfo", additionalInfoMenu()))
        m.addItem(item("Show Previews", "view-preview", #selector(togglePreviews(_:))))
        m.addItem(item("Show Hidden Files", "view-hidden", #selector(toggleHiddenFiles(_:))))
        m.addItem(.separator())
        m.addItem(item("Restore to Defaults", "edit-reset", #selector(restoreViewDefaults(_:))))
        m.addItem(item("Adjust View Display Style…", "configure", #selector(adjustViewStyle(_:))))
        return m
    }

    func splitMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Split View to Tabs", "tab-new", #selector(splitToTabs(_:))))
        m.addItem(item(tab.activeIsSecondary ? "Pop out Right View" : "Pop out Left View", "window-new", #selector(popOutSplit(_:))))
        return m
    }

    /// View › Show Panels (menu bar and hamburger).
    static func panelsMenu() -> NSMenu {
        let m = NSMenu(title: "Show Panels")
        for (i, p) in panelToggles.enumerated() {
            m.addItem(.make(p.title, #selector(togglePanel(_:)), key: KeyEquivalent.f(p.fkey), mods: [], icon: p.icon, tag: i))
        }
        m.addItem(.separator())
        m.addItem(.make("Focus Places Panel", #selector(focusPlaces(_:)), key: "p"))
        m.addItem(.make("Focus Terminal Panel", #selector(focusTerminal(_:)), key: KeyEquivalent.f(4), mods: [.command, .shift]))
        return m
    }

    /// Create New ▸ (menu bar, hamburger and context menus).
    static func createNewMenu() -> NSMenu {
        let m = NSMenu(title: "Create New")
        m.addItem(.make("Folder…", #selector(createFolder(_:)), key: "n", mods: [.command, .shift], icon: "folder-new"))
        m.addItem(.separator())
        for k in NewItemKind.allCases where k != .folder {
            m.addItem(.make(k.menuTitle, #selector(createFile(_:)), icon: k.icon, tag: k.rawValue))
        }
        return m
    }

    /// The hamburger menu, mirroring Dolphin's DolphinMainWindow::updateHamburgerMenu.
    func hamburgerMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(sub("Create New", "list-add", Self.createNewMenu()))
        m.addItem(item("Select Files and Folders", "edit-select", #selector(toggleSelectionMode(_:))))
        m.addItem(item("Undo", "edit-undo", #selector(undoFileOperation(_:))))
        m.addItem(item("Redo", "edit-redo", #selector(redoFileOperation(_:))))
        m.addItem(item("Filter…", "view-filter", #selector(showFilterBar(_:))))
        m.addItem(.separator())
        m.addItem(item("New Window", "window-new", #selector(newWindow(_:))))
        m.addItem(item("New Tab", "tab-new", #selector(newTab(_:))))
        if !closedTabs.isEmpty {
            let rc = NSMenu()
            for (i, t) in closedTabs.reversed().enumerated() {
                rc.addItem(item(t.url.lastPathComponent, "folder", #selector(reopenClosedTab(_:)), tag: closedTabs.count - 1 - i))
            }
            m.addItem(sub("Recently Closed Tabs", "edit-undo", rc))
        }
        m.addItem(item("Open Terminal", "utilities-terminal", #selector(openTerminal(_:))))
        m.addItem(.separator())
        let zoom = NSMenu()
        zoom.addItem(item("Zoom In", "zoom-in", #selector(zoomIn(_:))))
        zoom.addItem(item("Reset Zoom Level", "zoom-original", #selector(zoomReset(_:))))
        zoom.addItem(item("Zoom Out", "zoom-out", #selector(zoomOut(_:))))
        m.addItem(sub("Zoom", "zoom", zoom))
        m.addItem(sub("Show Panels", "view-sidetree", Self.panelsMenu()))
        m.addItem(.separator())
        let conf = NSMenu()
        conf.addItem(item("Configure Keyboard Shortcuts…", "configure-shortcuts", #selector(AppDelegate.configureShortcuts(_:))))
        conf.addItem(item("Settings…", "configure", #selector(AppDelegate.showSettings(_:))))
        m.addItem(sub("Configure", "configure", conf))
        m.addItem(sub("More", "overflow-menu", AppDelegate.shared.mainMenuCopy()))
        return m
    }

    @objc func reopenClosedTab(_ s: NSMenuItem) {
        guard closedTabs.indices.contains(s.tag) else { return }
        let t = closedTabs.remove(at: s.tag)
        addTab(url: t.url, split: t.split)
    }
}
