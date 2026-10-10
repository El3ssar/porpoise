import AppKit
import PorpoiseCore
import PorpoiseServices

extension MainWindowController {
    // MARK: Edit

    @objc func undoFileOperation(_ sender: Any?) { FileOperationsController.shared.undo(window: window); view.reload() }
    @objc func redoFileOperation(_ sender: Any?) { FileOperationsController.shared.redo(window: window); view.reload() }

    @objc func cut(_ sender: Any?) {
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be cut."); return }
        FileOperationsController.shared.copy(selectedURLs, cut: true)
    }

    @objc func copy(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { enterSelectionMode(prompt: "Select the files and folders that should be copied."); return }
        FileOperationsController.shared.copy(urls, cut: false)
        view.statusBar.showMessage(urls.count == 1 ? "Copied “\(urls[0].lastPathComponent)”." : "Copied \(urls.count) items.")
    }

    /// Paths of local items; full URLs (sftp://…, recent:/…) for everything else.
    @objc func copyLocation(_ sender: Any?) {
        let locations = actionTargets.map { $0.isFileURL ? $0.path : $0.absoluteString }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(locations.joined(separator: "\n"), forType: .string)
        view.statusBar.showMessage("Copied the location to the clipboard.")
    }

    @objc func paste(_ sender: Any?) {
        var target = view.url
        let sel = view.model.selectedItems
        if (sender as? NSMenuItem)?.representedObject as? String == Self.pasteIntoFolder, sel.count == 1, sel[0].isBrowsableFolder {
            target = sel[0].url
        }
        let c = view
        FileOperationsController.shared.paste(into: target, window: window) { results in
            c.model.selection = Set(results)
            if let f = results.first { c.pendingSelect = f }
            c.reload()
        }
    }

    @objc func showFilterBar(_ sender: Any?) {
        if !view.filterBar.isHidden && window?.firstResponder === view.filterBar.field.currentEditor() {
            view.filterBarClosed(view.filterBar)
        } else {
            view.showFilterBar()
        }
    }

    @objc func showSearch(_ sender: Any?) {
        if !view.searchBar.isHidden && sender is FlatButton { view.searchBarClosed(view.searchBar) } else { view.showSearch() }
        syncToActiveView()
    }

    @objc override func selectAll(_ sender: Any?) {
        view.model.selection = Set(view.model.rows.map(\.item.url))
        view.list.needsDisplay = true
    }

    @objc func invertSelection(_ sender: Any?) {
        let all = Set(view.model.rows.map(\.item.url))
        view.model.selection = all.subtracting(view.model.selection)
        view.list.needsDisplay = true
    }

    @objc func toggleSelectionMode(_ sender: Any?) {
        view.selectionMode.toggle()
        window?.makeFirstResponder(view.list)
    }

    /// Actions triggered with nothing selected enter selection mode with a prompt (Dolphin 23.08+).
    func enterSelectionMode(prompt: String) {
        view.selectionMode = true
        view.selectionTop.prompt = prompt
        window?.makeFirstResponder(view.list)
    }

    @objc func copyToOtherView(_ sender: Any?) {
        guard let other = tab.inactive else { return }
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be copied to the other view."); return }
        FileOperationsController.shared.run(.copy, selectedURLs, to: other.url, window: window)
    }

    @objc func moveToOtherView(_ sender: Any?) {
        guard let other = tab.inactive else { return }
        guard hasSelection else { enterSelectionMode(prompt: "Select the files and folders that should be moved to the other view."); return }
        FileOperationsController.shared.run(.move, selectedURLs, to: other.url, window: window)
    }
}
