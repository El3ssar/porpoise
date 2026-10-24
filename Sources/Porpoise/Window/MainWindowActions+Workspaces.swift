import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - Named workspaces

extension MainWindowController {
    /// Window › Workspaces: each saved workspace (⌥ opens it in a new window), then Delete. Save Workspace… follows it.
    func workspacesMenu() -> NSMenu {
        let m = NSMenu()
        let all = Settings.shared.workspaces
        if all.isEmpty {
            let none = m.addItem(withTitle: "No Saved Workspaces", action: nil, keyEquivalent: "")
            none.isEnabled = false
        }
        for w in all {
            m.addItem(.make(w.name, #selector(openWorkspace(_:)), mods: [], icon: "view-group", obj: w.id.uuidString))
            let alt = NSMenuItem.make(
                "\(w.name) in New Window", #selector(openWorkspaceInNewWindow(_:)), mods: [], icon: "window-new", obj: w.id.uuidString)
            alt.keyEquivalentModifierMask = .option
            alt.isAlternate = true
            m.addItem(alt)
        }
        if !all.isEmpty {
            m.addItem(.separator())
            let delete = NSMenu()
            for w in all { delete.addItem(.make(w.name, #selector(deleteWorkspace(_:)), mods: [], obj: w.id.uuidString)) }
            m.addItem(.submenu("Delete Workspace", icon: "edit-delete", delete))
        }
        return m
    }

    private func workspace(_ sender: Any?) -> Workspace? {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let id = UUID(uuidString: raw) else { return nil }
        return Settings.shared.workspaces.first { $0.id == id }
    }

    /// Saves this window's view under a name; a name already in use asks before replacing that workspace.
    @objc func saveWorkspace(_ sender: Any?) {
        WorkspaceSaveSheet.run(on: window, layout: captureLayout())
    }

    @objc func openWorkspace(_ sender: Any?) {
        if let w = workspace(sender) { open(w) }
    }

    /// A window made from the workspace alone: no Home tab first, which it would replace.
    @objc func openWorkspaceInNewWindow(_ sender: Any?) {
        guard let w = workspace(sender) else { return }
        guard AppDelegate.shared.newWindow(layout: w.layout) else { return cantOpen(w) }
        AppDelegate.shared.windows.last.map { $0.window?.makeFirstResponder($0.view.list) }
    }

    /// Shows `w` here: its tabs replace this window's, which Undo Close Tab can bring back (only once they're replaced).
    func open(_ w: Workspace) {
        guard w.layout.normalized != nil else { return cantOpen(w) }
        let replaced = tabs
        applyLayout(w.layout)
        replaced.forEach(rememberClosed)
        window?.makeFirstResponder(view.list)
    }

    private func cantOpen(_ w: Workspace) {
        Prompt.message("“\(w.name)” can’t be opened.", detail: "It was saved by a newer version of Porpoise.", warning: true, on: window)
    }

    @objc func deleteWorkspace(_ sender: Any?) {
        guard let w = workspace(sender) else { return }
        let a = NSAlert()
        a.messageText = "Delete the workspace “\(w.name)”?"
        a.informativeText = "Its tabs and folders stay as they are; only the saved workspace goes."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        a.runSheet(for: window) { r in
            if r == .alertFirstButtonReturn { Settings.shared.deleteWorkspace(id: w.id) }
        }
    }
}

// MARK: - Quick Select

extension MainWindowController {
    /// Edit › Select Matching…: picks items by name pattern, extension or tag.
    @objc func selectMatching(_ sender: Any?) { QuickSelectSheet.run(for: self, action: .select) }

    /// Edit › Deselect Matching…: the same, taking the matching items out of the selection.
    @objc func deselectMatching(_ sender: Any?) { QuickSelectSheet.run(for: self, action: .remove) }

    /// The active view's items as Quick Select sees them (tags only where they're read: local files).
    var quickSelectCandidates: [QuickSelect.Candidate] {
        let model = view.model
        return model.rows.map { row in
            let item = row.item
            return QuickSelect.Candidate(
                id: item.url, name: item.name, isFolder: item.isDirectory, tags: item.url.isFileURL ? model.tags(for: item).map(\.name) : [])
        }
    }

    /// Changes the active view's selection by `q`; returns how many items are selected after, nil when `q` can't
    /// match anything.
    @discardableResult
    func applyQuickSelect(_ q: QuickSelect, action: QuickSelect.Action) -> Int? {
        let v = view
        guard let selection = q.apply(action, to: v.model.selection, in: quickSelectCandidates) else { return nil }
        v.model.selection = selection
        if let i = v.model.rows.firstIndex(where: { selection.contains($0.item.url) }) {
            v.model.currentURL = v.model.rows[i].item.url
            v.list.scrollToItem(i)
        }
        v.list.needsDisplay = true
        v.updateStatus()
        window?.makeFirstResponder(v.list)
        return selection.count
    }
}
