import AppKit
import PorpoiseCore
import PorpoiseServices

struct GitChangesRequest {
    let item: FileItem
    let status: GitFolderStatus
}

extension MainWindowController {
    func addGitChanges(to menu: NSMenu, item: FileItem, in container: ViewContainer, single: Bool) {
        guard single, item.url.isFileURL, !item.isDirectory, !item.isSymlink,
            let status = container.model.gitStatus, let kind = status.status(for: item), kind != .ignored
        else { return }
        let entry = NSMenuItem(title: "Show Changes", action: #selector(showGitChanges(_:)), keyEquivalent: "")
        entry.target = self; entry.representedObject = GitChangesRequest(item: item, status: status)
        menu.addItem(entry)
    }

    @objc func showGitChanges(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? GitChangesRequest else { return }
        let item = request.item, status = request.status
        let bar = view.statusBar
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let comparison = try GitComparison(item: item, status: status)
                DispatchQueue.main.async { FileDiffWindow.present(git: comparison) }
            } catch {
                DispatchQueue.main.async { bar.showMessage("Git comparison unavailable or exceeds the size/time budget.") }
            }
        }
    }
}
