import AppKit
import PorpoiseCore
import PorpoiseServices

// MARK: - BreadcrumbDelegate

extension MainWindowController {
    func breadcrumb(_ b: BreadcrumbView, navigateTo url: URL, newTab: Bool) {
        let target: ViewContainer = (b === tab.navigators[1] ? tab.secondary : tab.primary) ?? view
        var isDir: ObjCBool = false
        if CloudAccounts.looksLikeLink(url.absoluteString) {
            openCloudLink(url, in: target, newTab: newTab)
            return
        }
        if !LocationKind.of(url).isSupported {
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

    /// A pasted cloud share link: opened with the connected account that can see it. A folder is browsed like any
    /// other, with Add to Places offered; a file opens (Google Docs in the browser); nobody can see it: Connect….
    func openCloudLink(_ link: URL, in target: ViewContainer, newTab: Bool) {
        let service = CloudProviderDescriptor.linkProvider(link.absoluteString)?.title ?? "cloud"
        target.statusBar.showMessage("Opening the \(service) link…")
        CloudAccounts.shared.resolveLink(link.absoluteString) { [weak self, weak target] result in
            guard let self, let target else { return }
            switch result {
            case .folder(let u):
                if newTab { self.addTab(url: u, select: true) } else { target.setURL(u) }
                target.onNextLoad = { [weak target] in
                    guard let target, !PlacesModel.shared.contains(u), target.model.loadError == nil else { return }
                    target.messageBar.show("Opened a folder from a link.", error: false, action: "Add to Places") { [weak target] in
                        PlacesModel.shared.add(u, title: u.folderName)
                        target?.messageBar.dismiss()
                    }
                    target.needsLayout = true
                }
            case .file(let u):
                if u.scheme == "https" {
                    NSWorkspace.shared.open(AccountActions.webLink(u, account: CloudAccounts.shared.account(for: u)))
                } else {
                    // A file without a web page: a copy opens, as from the folder.
                    RemoteOpener.open(FileItem(url: u, name: CloudAccounts.shared.info(for: u)?.name ?? u.folderName, isDirectory: false))
                }
            case .noAccess:
                target.messageBar.show("None of your accounts can open this folder.", error: false, action: "Connect…") {
                    [weak self, weak target] in
                    ConnectSheet.run(window: self?.window) { target?.setURL($0) }
                }
                target.needsLayout = true
            case .notALink:
                target.messageBar.show("That isn’t a \(service) link Porpoise can open.", error: true)
                target.needsLayout = true
            }
        }
    }

    func breadcrumbActivated(_ b: BreadcrumbView) {
        if tab.isSplit { tab.setActive(secondary: b === tab.navigators[1]); syncToActiveView() }
    }

    func breadcrumb(_ b: BreadcrumbView, drop urls: [URL], onto folder: URL, operation: NSDragOperation) {
        FileOperationsController.shared.handleDrop(urls, onto: folder, operation: operation, in: b)
    }

    // MARK: PlacesPanelDelegate

    func places(_ p: PlacesPanel, open url: URL, newTab: Bool, splitView: Bool) {
        if newTab { addTab(url: url, select: false); return }
        if splitView, tab.isSplit || tab.canSplit {
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

    func places(_ p: PlacesPanel, drop urls: [URL], onto url: URL, operation: NSDragOperation) {
        if url == PlacesModel.airDropURL {
            SharingCoordinator.shared.share(urls, mode: .airDrop, from: p)
            return
        }
        if LocationKind.of(url) == .trash {
            FileOperationsController.shared.trash(urls, window: window)
            return
        }
        FileOperationsController.shared.handleDrop(urls, onto: url, operation: operation, in: places)
    }

    func places(_ p: PlacesPanel, emptyTrash: Void) { FileOperationsController.shared.emptyTrash(window: window) }
    func places(_ p: PlacesPanel, properties url: URL) { PropertiesWindow.show(urls: [url]) }
    func placesWantsViewFocus(_ p: PlacesPanel) { window?.makeFirstResponder(view.list) }
}
