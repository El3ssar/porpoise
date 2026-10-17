import AppKit
import PorpoiseCore
import PorpoiseServices

private enum LinkedSide { case left, right }

extension MainWindowController {
    @objc func toggleLinkedBrowsing(_ sender: Any?) {
        if tab.linkedRoots != nil {
            tab.linkedRoots = nil; tab.missingCounterpart?.removeFromSuperview(); tab.missingCounterpart = nil
            tab.containers.forEach { $0.preservesMissingLocation = false }
        } else {
            if !tab.isSplit { tab.openSplit(); tab.secondary?.delegate = self }
            if let secondary = tab.secondary { tab.linkedRoots = (tab.primary.url, secondary.url) }
            tab.containers.forEach { $0.preservesMissingLocation = true }
        }
        syncToActiveView()
    }
    func linkedNavigationChanged(_ container: ViewContainer) {
        guard let tab = tabs.first(where: { $0.containers.contains(where: { $0 === container }) }), !tab.linkUpdating,
            let other = container === tab.primary ? tab.secondary : tab.primary
        else { return }
        tab.linkGeneration += 1
        let generation = tab.linkGeneration
        if let roots = tab.linkedRoots {
            let sourceRoot = container === tab.primary ? roots.left : roots.right
            let targetRoot = container === tab.primary ? roots.right : roots.left
            if let target = LinkedBrowsing.counterpart(container.url, sourceRoot: sourceRoot, targetRoot: targetRoot) {
                // Widen anchors on Up so Back/Forward and re-entering the old root stay paired.
                if LinkedBrowsing.relativePath(container.url, below: sourceRoot) == nil {
                    tab.linkedRoots = container === tab.primary ? (container.url, target) : (target, container.url)
                }
                if other.url != target {
                    tab.linkUpdating = true
                    if container.historyTraversal < 0, let index = other.history.backList.firstIndex(of: target) {
                        other.goBack(index + 1)
                    } else if container.historyTraversal > 0, let index = other.history.forwardList.firstIndex(of: target) {
                        other.goForward(index + 1)
                    } else {
                        let prior = other.url
                        other.setURL(target, selecting: prior.deletingLastPathComponent() == target ? prior : nil)
                    }
                    tab.linkUpdating = false
                }
            } else {
                // An unrelated path edit starts a new pair at the two visible locations.
                tab.linkedRoots = (tab.primary.url, tab.secondary!.url)
            }
        }
        tab.missingCounterpart?.removeFromSuperview(); tab.missingCounterpart = nil
        guard tab.linkedRoots != nil else { return }
        let target = other.url
        DispatchQueue.global(qos: .utility).async { [weak self, weak tab, weak other] in
            let exists = LocationOperations(for: target).folderExists(target)
            DispatchQueue.main.async {
                guard let self, let tab, let other, tab.linkGeneration == generation, tab.linkedRoots != nil, !exists else {
                    return
                }
                self.showMissingCounterpart(in: tab, side: other === tab.secondary ? .right : .left, target: target)
            }
        }
    }
    private func showMissingCounterpart(in tab: PorpoiseTab, side: LinkedSide, target: URL) {
        let roots = tab.linkedRoots ?? (tab.primary.url, tab.secondary?.url ?? tab.primary.url)
        let names = LinkedBrowsing.sideNames(roots.0, roots.1)
        let sideName = side == .left ? names.0 : names.1
        let placeholder = tab.missingCounterpart ?? LinkedPanePlaceholder()

        placeholder.content.configure(
            symbol: "folder.badge.questionmark", title: "No “\(target.lastPathComponent)” in \(sideName)",
            detail: "Linked browsing will follow again when you open a folder that exists on both sides.",
            button: "Create “\(target.lastPathComponent)”"
        ) { [weak self, weak tab] in if let tab { self?.createLinkedCounterpart(target, in: tab) } }
        placeholder.unlink.isHidden = false; placeholder.unlink.onClick = { [weak self] in self?.toggleLinkedBrowsing(nil) }
        placeholder.choose.isHidden = false
        placeholder.choose.onClick = { [weak self, weak tab] in if let tab { self?.chooseLinkedCounterpart(in: tab, side: side) } }
        placeholder.statusText = "Not in \(sideName)"
        tab.missingCounterpart = placeholder; tab.missingOnRight = side == .right
        if placeholder.superview !== tab { tab.addSubview(placeholder) }
        tab.needsLayout = true
        if tab === self.tab { syncToActiveView() }
    }
    private func chooseLinkedCounterpart(in tab: PorpoiseTab, side: LinkedSide) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Choose Folder"
        let container = side == .left ? tab.primary : tab.secondary!
        panel.directoryURL = container.url.deletingLastPathComponent()
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self, weak tab, weak container] response in
            guard let self, let tab, let container, response == .OK, let url = panel.url else { return }
            tab.linkUpdating = true; container.setURL(url); tab.linkUpdating = false
            tab.linkedRoots = (tab.primary.url, tab.secondary!.url)
            self.linkedNavigationChanged(container)
        }
    }
    private func createLinkedCounterpart(_ url: URL, in selectedTab: PorpoiseTab) {
        DispatchQueue.global(qos: .utility).async { [weak self, weak selectedTab] in
            let result = Result { try LocationOperations(for: url).makeFolder(url) }
            DispatchQueue.main.async {
                guard let self, let selectedTab else { return }
                switch result {
                case .success:
                    selectedTab.missingCounterpart?.removeFromSuperview(); selectedTab.missingCounterpart = nil;
                    selectedTab.containers.forEach { $0.reload() }
                case .failure(let error): self.view.messageBar.show(error.localizedDescription, error: true)
                }
                self.syncToActiveView()
            }
        }
    }
}
