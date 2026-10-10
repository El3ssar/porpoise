import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - BreadcrumbDelegate

extension MainWindowController {
    func breadcrumb(_ b: BreadcrumbView, navigateTo url: URL, newTab: Bool) {
        let target: ViewContainer = (b === tab.navigators[1] ? tab.secondary : tab.primary) ?? view
        var isDir: ObjCBool = false
        if !url.isFileURL && !RemoteFS.isRemote(url) && !NetworkMounts.needsMount(url) && !Self.virtualSchemes.contains(url.scheme ?? "") {
            target.messageBar.show("Porpoise can't open “\(url.scheme ?? "")://” locations.", error: true)
            target.needsLayout = true
            return
        }
        if url.isFileURL && !(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue) {
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url); return }
            target.messageBar.show("The folder “\(url.path)” does not exist.", error: true)
            target.needsLayout = true
            return
        }
        if newTab { addTab(url: url, select: false) } else { target.setURL(url) }
        window?.makeFirstResponder(target.list)
    }

    /// Locations the app lists itself rather than a file system (Network, Recent, Tags, Smart Folders).
    private static let virtualSchemes: Set<String> = ["network", "recent", "tags", "smart"]

    func breadcrumbActivated(_ b: BreadcrumbView) {
        if tab.isSplit { tab.setActive(secondary: b === tab.navigators[1]); syncToActiveView() }
    }

    func breadcrumb(_ b: BreadcrumbView, drop urls: [URL], onto folder: URL) {
        FileOperationsController.shared.handleDrop(urls, onto: folder, operation: dropOperationForCurrentModifiers(), in: b)
    }

    // MARK: PlacesPanelDelegate

    func places(_ p: PlacesPanel, open url: URL, newTab: Bool, splitView: Bool) {
        if newTab { addTab(url: url, select: false); return }
        if splitView {
            if !tab.isSplit { tab.openSplit(url: url); tab.secondary?.delegate = self } else { tab.inactive?.setURL(url) }
            syncToActiveView()
            return
        }
        if view.url.standardizedFileURL == url.standardizedFileURL {
            // Clicking the current place again clears the filter (Dolphin).
            view.filterBarClosed(view.filterBar)
        }
        view.setURL(url)
        // Keyboard browsing in Places keeps focus there; clicks hand it to the view (in Applications: to the app
        // library, ready to type a search).
        let byKeyboard = NSApp.currentEvent?.type == .keyDown
        if !byKeyboard || window?.firstResponder !== p {
            window?.makeFirstResponder((view.showsApps ? view.apps?.grid : nil) ?? view.list)
        }
    }

    func places(_ p: PlacesPanel, drop urls: [URL], onto url: URL) {
        if url.standardizedFileURL == TrashInfo.folder.standardizedFileURL {
            FileOperationsController.shared.trash(urls, window: window)
            return
        }
        FileOperationsController.shared.handleDrop(urls, onto: url, operation: dropOperationForCurrentModifiers(), in: places)
    }

    func places(_ p: PlacesPanel, emptyTrash: Void) { FileOperationsController.shared.emptyTrash(window: window) }
    func places(_ p: PlacesPanel, properties url: URL) { PropertiesWindow.show(urls: [url]) }
    func placesWantsViewFocus(_ p: PlacesPanel) { window?.makeFirstResponder(view.list) }
}

private func dropOperationForCurrentModifiers() -> NSDragOperation {
    let m = NSEvent.modifierFlags
    if m.contains(.command) && m.contains(.option) { return .link }
    if m.contains(.option) { return .copy }
    if m.contains(.command) { return .move }
    return .generic
}
