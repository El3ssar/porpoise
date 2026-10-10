import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz

// Quick Look: a Mac addition, bound to Space.
extension MainWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }

    private var quickLookURLs: [URL] {
        let sel = selectedURLs
        if !sel.isEmpty { return sel }
        return view.model.currentURL.map { [$0] } ?? []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        // The selection can change between the count and this call.
        quickLookURLs[safe: index].map { $0 as NSURL }
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let u = item.previewItemURL, let r = view.list.iconScreenRect(for: u) else { return .zero }
        return r
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown { view.list.keyDown(with: event); panel.reloadData(); return true }
        return false
    }
}
