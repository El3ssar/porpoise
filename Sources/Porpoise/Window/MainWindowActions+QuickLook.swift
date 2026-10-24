import AppKit
import PorpoiseCore
import PorpoiseServices

extension MainWindowController {
    /// Selection and pane focus changes follow the same app-owned preview window.
    func refreshQuickLook() {
        guard spacePreview?.isVisible == true else { return }
        showSpacePreview()
    }

    func showSpacePreview() {
        guard let window else { return }
        let selected = view.model.selectedItems
        let items: [FileItem]
        if !selected.isEmpty {
            items = selected
        } else if let current = view.model.currentURL {
            items = [FileItem(url: current, name: LocationNaming.title(for: current), isDirectory: true, contentType: "public.folder")]
        } else {
            items = []
        }
        if spacePreview == nil {
            let panel = SpacePreviewPanel()
            panel.onArrow = { [weak self] event in
                guard let self else { return }
                self.view.list.keyDown(with: event)
                self.refreshQuickLook()
            }
            panel.onOpenWith = { item, app in
                let launch: (URL) -> Void = { NSWorkspace.shared.open([$0], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
                if item.url.isFileURL { launch(item.url) } else { RemoteOpener.open(item, using: launch) }
            }
            spacePreview = panel
        }
        let source = items.first.flatMap { view.list.iconScreenRect(for: $0.url) } ?? .zero
        spacePreview?.show(items, relativeTo: window, source: source)
    }
}
