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
            let drive = RemoteFS.provider(for: url) as? DriveProvider, let client = drive.client,
            let file = drive.metadata(for: url), file.mimeType.hasPrefix("video/") || file.mimeType.hasPrefix("audio/"),
            let window
        else { return false }
        if driveMediaQuickLook == nil {
            let panel = DriveMediaPreviewPanel()
            panel.onArrow = { [weak self] event in
                guard let self else { return }
                self.view.list.keyDown(with: event)
                if !self.showDriveMediaQuickLook() { self.driveMediaQuickLook?.close(); self.quickLook(nil) }
            }
            driveMediaQuickLook = panel
        }
        driveMediaQuickLook?.show(file, client: client, relativeTo: window)
        return true
    }

    func prepareDriveQuickLook() {
        driveQuickLook?.cancel(); driveQuickLookLoading = []; driveQuickLookURLs = [:]
        let urls = quickLookURLs.filter { $0.scheme == "gdrive" && driveQuickLookURLs[$0] == nil }
        driveQuickLookLoading = Set(urls)
        driveQuickLook = Task { @MainActor [weak self] in
            for url in urls {
                guard let drive = RemoteFS.provider(for: url) as? DriveProvider else { continue }
                do {
                    self?.view.statusBar.showMessage("Loading preview…")
                    guard let client = drive.client else { throw DriveError.reconnect }
                    let file: DriveFile
                    if let cached = drive.metadata(for: url) {
                        file = cached
                    } else {
                        guard let location = DriveLocation(url: url), case .folder(let id, _) = location.collection else {
                            throw DriveError.invalidLocation
                        }
                        file = try await client.file(id, resourceKey: location.resourceKey)
                    }
                    _ = try await client.progressivePreview(file) { [weak self] local in
                        try Task.checkCancellation()
                        guard let self else { return }
                        self.driveQuickLookURLs[url] = local
                        QLPreviewPanel.shared().reloadData()
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
        if url.scheme == "gdrive" {
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
