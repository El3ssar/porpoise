import AppKit
import PorpoiseCore
import PorpoiseServices

extension PlacesPanel {
    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let i = rowIndex(at: convert(event.locationInWindow, from: nil))
        func add(_ title: String, _ icon: String?, _ action: Selector, _ obj: Any? = nil) {
            let it = m.addItem(withTitle: title, action: action, keyEquivalent: "")
            it.target = self
            it.representedObject = obj
            if let icon { it.image = Icons.shared.menuIcon(icon) }
        }
        if let entry = entry(at: i), let pair = SyncCoordinator.shared.pair(for: entry.url) {
            func syncItem(_ title: String, _ action: Selector) {
                let item = m.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self; item.representedObject = pair.id.uuidString
            }
            syncItem("Sync Now", #selector(syncNow(_:)))
            syncItem("Compare", #selector(compareSync(_:))); m.addItem(.separator())
            if pair.automatic { syncItem(pair.paused ? "Resume Keeping in Sync" : "Pause Keeping in Sync", #selector(pauseSync(_:))) }
            syncItem("Edit Sync…", #selector(editSync(_:)))
            syncItem("Rename…", #selector(renameSync(_:))); m.addItem(.separator())
            syncItem("Show in Activity", #selector(syncActivity)); m.addItem(.separator())
            syncItem("Remove Sync…", #selector(removeSync(_:)))
            return m
        }
        if let e = entry(at: i) {
            add("Open in New Tab", "tab-new", #selector(openNewTab(_:)), e.url)
            add("Open in New Window", "window-new", #selector(openNewWindow(_:)), e.url)
            add("Open in Split View", "view-split-left-right", #selector(openSplit(_:)), e.url)
            m.addItem(.separator())
            if e.icon == "user-trash" {
                add("Empty Trash", "trash-empty", #selector(emptyTrash))
                m.addItem(.separator())
            }
            if e.isEjectable {
                add("Eject", "media-eject", #selector(ejectMenu(_:)), e)
                m.addItem(.separator())
            }
            // Only bookmarks can be edited; devices, tags and detected cloud folders/phones can't.
            if PlacesModel.shared.isUserEntry(e) {
                add("Edit…", "edit-entry", #selector(editEntry(_:)), e)
                add(e.hidden ? "Show" : "Hide", e.hidden ? "view-visible" : "view-hidden", #selector(toggleHidden(_:)), e)
                add("Remove from Places", "bookmark-remove", #selector(removeEntry(_:)), e)
            }
            if !PlacesModel.shared.hiddenSections.contains(e.section) {
                add("Hide Section “\(e.section.rawValue)”", "view-hidden", #selector(hideSection(_:)), e.section.rawValue)
            }
            m.addItem(.separator())
        } else if let i, case .header(let sec) = rows[i].kind {
            let folded = PlacesModel.shared.collapsedSections.contains(sec)
            add(folded ? "Expand “\(sec.rawValue)”" : "Collapse “\(sec.rawValue)”", nil, #selector(toggleSection(_:)), sec.rawValue)
            if !PlacesModel.shared.isLocked {
                let order = PlacesModel.shared.sections().map(\.0)
                if let n = order.firstIndex(of: sec) {
                    if n > 0 { add("Move Section Up", "go-up", #selector(moveSectionUp(_:)), sec.rawValue) }
                    if n < order.count - 1 { add("Move Section Down", "go-down", #selector(moveSectionDown(_:)), sec.rawValue) }
                }
            }
            // Hidden sections are listed while "Show Hidden Places" is on; they can be shown again one by one.
            if PlacesModel.shared.hiddenSections.contains(sec) {
                add("Show Section “\(sec.rawValue)”", "view-visible", #selector(showSection(_:)), sec.rawValue)
            } else {
                add("Hide Section “\(sec.rawValue)”", "view-hidden", #selector(hideSection(_:)), sec.rawValue)
            }
            m.addItem(.separator())
        }
        let model = PlacesModel.shared
        let anyFolded = !model.collapsedSections.isEmpty
        add(anyFolded ? "Expand All Sections" : "Collapse All Sections", nil, #selector(toggleAllSections))
        let lock = m.addItem(withTitle: "Lock Places", action: #selector(toggleLock), keyEquivalent: "")
        lock.target = self
        lock.state = model.isLocked ? .on : .off
        lock.toolTip = "Locked: places and sections can't be dragged or reordered."
        m.addItem(.separator())
        add("Add Entry…", "bookmark-new", #selector(addEntry))
        add("Add Network Folder…", "folder-network", #selector(addNetworkFolder))
        let showAll = m.addItem(withTitle: "Show Hidden Places", action: #selector(toggleShowHidden), keyEquivalent: "")
        showAll.target = self
        showAll.state = PlacesModel.shared.showHidden ? .on : .off
        m.addItem(iconSizeMenuItem())
        if !PlacesModel.shared.hiddenSections.isEmpty {
            add("Show All Sections", nil, #selector(showSections))
        }
        add("Reset to Defaults", nil, #selector(resetPlaces))
        if let e = entry(at: i), e.url.isFileURL {
            m.addItem(.separator())
            add("Properties", "document-properties", #selector(properties(_:)), e.url)
        }
        return m
    }

    private func iconSizeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Icon Size", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for (t, s) in [("Small (16x16)", 16), ("Medium (22x22)", 22), ("Large (32x32)", 32), ("Huge (48x48)", 48)] {
            let it = sm.addItem(withTitle: t, action: #selector(setIconSize(_:)), keyEquivalent: "")
            it.target = self
            it.tag = s
            it.state = Settings.shared.placesIconSize == s ? .on : .off
        }
        item.submenu = sm
        return item
    }

    @objc private func openNewTab(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { delegate?.places(self, open: u, newTab: true, splitView: false) }
    }
    @objc private func openSplit(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { delegate?.places(self, open: u, newTab: false, splitView: true) }
    }
    @objc private func openNewWindow(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { AppDelegate.shared.newWindow(at: u) }
    }
    @objc private func properties(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { delegate?.places(self, properties: u) }
    }
    @objc private func emptyTrash() { delegate?.places(self, emptyTrash: ()) }
    @objc private func ejectMenu(_ s: NSMenuItem) { if let e = s.representedObject as? PlaceEntry { eject(e) } }
    @objc private func toggleShowHidden() { PlacesModel.shared.showHidden.toggle() }
    @objc private func showSections() { PlacesModel.shared.hiddenSections = [] }
    @objc private func setIconSize(_ s: NSMenuItem) { Settings.shared.placesIconSize = s.tag }
    @objc private func resetPlaces() { PlacesModel.shared.resetDefaults() }
    @objc private func addNetworkFolder() { AddNetworkFolderDialog.run(window: window) }

    @objc private func toggleSection(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let sec = PlaceSection(rawValue: raw) { toggleSectionAnimated(sec) }
    }

    @objc private func toggleAllSections() {
        let m = PlacesModel.shared
        let new: Set<PlaceSection> = m.collapsedSections.isEmpty ? Set(m.sections().map(\.0)) : []
        guard new != m.collapsedSections else { return }
        animateNextReload = true
        m.collapsedSections = new
    }

    @objc private func toggleLock() { PlacesModel.shared.isLocked.toggle() }

    @objc private func moveSectionUp(_ s: NSMenuItem) { moveSection(s, by: -1) }
    @objc private func moveSectionDown(_ s: NSMenuItem) { moveSection(s, by: 1) }

    /// Moves a section past its visible neighbour (hidden or empty sections keep their place in the stored order).
    private func moveSection(_ s: NSMenuItem, by delta: Int) {
        guard let raw = s.representedObject as? String, let sec = PlaceSection(rawValue: raw) else { return }
        let shown = PlacesModel.shared.sections().map(\.0)
        guard let n = shown.firstIndex(of: sec), shown.indices.contains(n + delta) else { return }
        if delta < 0 {
            PlacesModel.shared.moveSection(sec, before: shown[n - 1])
        } else {
            PlacesModel.shared.moveSection(sec, before: n + 2 < shown.count ? shown[n + 2] : nil)
        }
    }

    @objc private func hideSection(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let sec = PlaceSection(rawValue: raw) { PlacesModel.shared.hiddenSections.insert(sec) }
    }

    @objc private func showSection(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let sec = PlaceSection(rawValue: raw) { PlacesModel.shared.hiddenSections.remove(sec) }
    }

    @objc private func toggleHidden(_ s: NSMenuItem) {
        guard let e = s.representedObject as? PlaceEntry else { return }
        PlacesModel.shared.setHidden(e, !e.hidden)
    }

    @objc private func removeEntry(_ s: NSMenuItem) {
        guard let e = s.representedObject as? PlaceEntry else { return }
        PlacesModel.shared.remove(e)
    }

    @objc private func editEntry(_ s: NSMenuItem) {
        guard let e = s.representedObject as? PlaceEntry else { return }
        PlaceEditDialog.run(title: "Edit Places Entry", label: e.title, url: e.url, window: window) { label, url in
            PlacesModel.shared.update(e, title: label, url: url)
        }
    }

    @objc private func addEntry() {
        let u = currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        let label = PlacesModel.shared.title(for: u) ?? (RemoteFS.isRemote(u) ? RemoteFS.displayName(for: u) : u.lastPathComponent)
        PlaceEditDialog.run(title: "Add Places Entry", label: label, url: u, window: window) { label, url in
            PlacesModel.shared.add(url, title: label)
        }
    }

    // MARK: Eject

    /// Ejects in the background (it can take seconds); the view leaves the volume first so it doesn't keep it busy.
    func eject(_ e: PlaceEntry) {
        guard ejecting.insert(e.url).inserted else { return }
        // Every view showing the volume (all windows, tabs and split sides) must let go of it.
        MainWindowController.leaveVolume(e.url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure: Error?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: e.url); failure = nil } catch { failure = error }
            DispatchQueue.main.async {
                guard let self else { return }
                self.ejecting.remove(e.url)
                guard let failure else { return }
                let a = NSAlert(error: failure)
                a.messageText = "Could not eject “\(e.title)”"
                if let w = self.window { a.beginSheetModal(for: w) } else { a.runModal() }
            }
        }
    }
}

extension PlacesPanel {
    private func savedSync(_ sender: NSMenuItem) -> SavedSync? {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return nil }
        return SyncCoordinator.shared.pairs.first { $0.id == id }
    }
    @objc private func syncNow(_ sender: NSMenuItem) {
        guard let pair = savedSync(sender), let window else { return }
        SyncSheetController(pair: pair, owner: window).present()
    }
    @objc private func compareSync(_ sender: NSMenuItem) {
        if let pair = savedSync(sender) { SyncCoordinator.shared.open(pair, window: window) }
    }
    @objc private func pauseSync(_ sender: NSMenuItem) {
        if let pair = savedSync(sender) { SyncCoordinator.shared.setPaused(pair, paused: !pair.paused) }
    }
    @objc private func editSync(_ sender: NSMenuItem) {
        if let pair = savedSync(sender) { SyncCoordinator.shared.review(pair.id, window: window, editing: true) }
    }
    @objc private func removeSync(_ sender: NSMenuItem) {
        if let pair = savedSync(sender) { SyncCoordinator.shared.remove(pair, window: window) }
    }
    @objc private func renameSync(_ sender: NSMenuItem) {
        if let pair = savedSync(sender) { renameSavedSync(pair) }
    }
    func renameSavedSync(_ pair: SavedSync) {
        guard let window, let index = rows.indices.first(where: { entry(at: $0).flatMap { SyncCoordinator.shared.pair(for: $0.url) }?.id == pair.id })
        else { return }
        let field = SyncInlineNameField(frame: .zero); field.stringValue = pair.name
        field.frame = CGRect(x: 40, y: rect(of: index).midY - 12, width: max(60, bounds.width - 48), height: 24)
        field.font = .systemFont(ofSize: 13)
        field.committed = { name in
            var next = pair; next.name = name; SyncCoordinator.shared.save(next)
        }
        addSubview(field); window.makeFirstResponder(field); field.selectText(nil)
    }
    @objc private func syncActivity() { ActivityWindowController.shared.show() }
}

private final class SyncInlineNameField: NSTextField, NSTextFieldDelegate {
    var committed: ((String) -> Void)?
    private var finished = false
    override init(frame: NSRect) { super.init(frame: frame); delegate = self; target = self; action = #selector(commit) }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func commit() {
        guard !finished else { return }; finished = true
        let name = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { committed?(name) }
        removeFromSuperview()
    }
    func controlTextDidEndEditing(_ obj: Notification) { commit() }
    override func cancelOperation(_ sender: Any?) { finished = true; removeFromSuperview() }
}
