import AppKit
import PorpoiseServices

extension MainWindowController {
    @objc func showGitChanges(_ sender: NSMenuItem) {
        guard let item = view.model.selectedItems.first, let status = view.model.gitStatus else { return }
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
