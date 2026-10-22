import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz

private final class LoadingDrivePreview: NSObject, QLPreviewItem {
    let previewItemURL: URL? = nil
    let previewItemTitle: String?
    init(loading: Bool) { previewItemTitle = loading ? "Loading preview…" : "Preview unavailable" }
}

// Quick Look: a Mac addition, bound to Space.
extension MainWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        driveQuickLook?.cancel(); driveQuickLook = nil; driveQuickLookLoading = []
        panel.dataSource = nil; panel.delegate = nil
    }

    @discardableResult func showDriveMediaQuickLook() -> Bool {
        guard quickLookURLs.count == 1, let url = quickLookURLs.first,
            let cloud = RemoteFS.provider(for: url) as? CloudFileProvider,
            let item = view.model.rows.first(where: { $0.item.url == url })?.item,
            item.utType?.conforms(to: .audiovisualContent) == true,
            let window
        else { return false }
        if driveMediaQuickLook == nil {
            let panel = CloudMediaPreviewPanel()
            panel.onArrow = { [weak self] event in
                guard let self else { return }
                self.view.list.keyDown(with: event)
                if !self.showDriveMediaQuickLook() { self.driveMediaQuickLook?.close(); self.quickLook(nil) }
            }
            driveMediaQuickLook = panel
        }
        driveMediaQuickLook?.show(item, provider: cloud, relativeTo: window)
        return true
    }

    func prepareDriveQuickLook() {
        driveQuickLook?.cancel(); driveQuickLookLoading = []; driveQuickLookURLs = [:]
        let urls = quickLookURLs.filter { (PlacesModel.isCloud($0) || $0.scheme == "archive") && driveQuickLookURLs[$0] == nil }
        driveQuickLookLoading = Set(urls)
        driveQuickLook = Task { @MainActor [weak self] in
            for url in urls {
                if url.scheme == "archive" {
                    do {
                        let local = try await ArchiveBrowser.localCopy(url)
                        try Task.checkCancellation()
                        self?.driveQuickLookURLs[url] = local
                        self?.driveQuickLookLoading.remove(url)
                        QLPreviewPanel.shared().reloadData()
                    } catch {
                        if !Task.isCancelled { self?.driveQuickLookLoading.remove(url); self?.view.statusBar.showMessage(error.localizedDescription) }
                    }
                    continue
                }
                guard let cloud = RemoteFS.provider(for: url) as? CloudFileProvider else { continue }
                do {
                    self?.view.statusBar.showMessage("Loading preview…")
                    _ = try await cloud.progressivePreview(url, context: .init()) { [weak self] local in
                        try Task.checkCancellation()
                        guard let self else { return }
                        self.driveQuickLookURLs[url] = local; QLPreviewPanel.shared().reloadData()
                    }
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.driveQuickLookLoading.remove(url)
                    QLPreviewPanel.shared().reloadData()
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.driveQuickLookLoading.remove(url)
                    self.view.statusBar.showMessage(error.localizedDescription)
                }
            }
        }
    }

    private var quickLookURLs: [URL] {
        let sel = selectedURLs
        if !sel.isEmpty { return sel }
        return view.model.currentURL.map { [$0] } ?? []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        // The selection can change between the count and this call.
        guard let url = quickLookURLs[safe: index] else { return nil }
        if PlacesModel.isCloud(url) || url.scheme == "archive" {
            return driveQuickLookURLs[url].map { $0 as NSURL } ?? LoadingDrivePreview(loading: driveQuickLookLoading.contains(url))
        }
        return url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let u = item.previewItemURL, let r = view.list.iconScreenRect(for: u) else { return .zero }
        return r
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown { view.list.keyDown(with: event); prepareDriveQuickLook(); panel.reloadData(); return true }
        return false
    }
}
