import AppKit
import PorpoiseServices

extension MainWindowController {
    @objc func shareItems(_ sender: Any?) { shareSelection(mode: .picker, sender: sender) }
    @objc func airDropItems(_ sender: Any?) { shareSelection(mode: .airDrop, sender: sender) }

    func shareSelection(mode: SharingCoordinator.Mode, sender: Any?, using coordinator: SharingCoordinator = .shared) {
        let urls = selectedURLs
        guard let first = urls.first else { return }
        let anchor = (sender as? NSView) ?? view.list
        let rect = anchor === view.list ? view.list.rect(for: first) ?? view.list.visibleRect : anchor.bounds
        coordinator.share(urls, mode: mode, from: anchor, rect: rect)
    }
}
