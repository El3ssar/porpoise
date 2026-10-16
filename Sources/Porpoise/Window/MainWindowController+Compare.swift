import AppKit
import PorpoiseCore
import PorpoiseServices

extension MainWindowController {
    @objc func toggleCompare(_ sender: Any?) {
        if tab.compareView != nil || tab.compareChooser != nil { stopComparing(); return }
        if let secondary = tab.secondary {
            startComparing(left: tab.primary.url, right: secondary.url)
        } else {
            let partner = tab.lastComparePartner ?? tab.primary.history.backList.first ?? tab.primary.url.deletingLastPathComponent()
            startComparing(left: tab.primary.url, right: partner)
        }
    }
    func startComparing(left: URL, right: URL, options: SyncCompareOptions = CompareModel.defaultOptions, preserveLinkRoots: Bool = false) {
        var previous = CACurrentMediaTime(), phases: [String: Double] = [:]
        func phase(_ name: String) { let now = CACurrentMediaTime(); phases[name] = (now - previous) * 1000; previous = now }
        let tab = tab
        if tab.comparisonSnapshots.isEmpty {
            tab.comparisonWasSecondary = tab.activeIsSecondary
            tab.comparisonPreviousLinks = tab.linkedRoots
            tab.comparisonSnapshots = tab.containers.map { ($0, $0.comparisonSnapshot()) }
        }
        tab.linkUpdating = true
        if !tab.isSplit { tab.openSplit(url: right, animated: false) }
        phase("split")
        tab.secondary?.delegate = self
        if let secondary = tab.secondary, !tab.comparisonSnapshots.contains(where: { $0.0 === secondary }) {
            tab.comparisonSnapshots.append((secondary, secondary.comparisonSnapshot()))
        }
        tab.containers.forEach { $0.suspendForComparison(true) }
        if tab.primary.url != left { tab.primary.setURL(left) }
        if tab.secondary?.url != right { tab.secondary?.setURL(right) }
        tab.compareChooser?.removeFromSuperview(); tab.compareChooser = nil
        tab.missingCounterpart?.removeFromSuperview(); tab.missingCounterpart = nil
        if !preserveLinkRoots || tab.linkedRoots == nil { tab.linkedRoots = (left, right) }
        tab.lastComparePartner = right
        tab.containers.forEach { $0.preservesMissingLocation = tab.linkedRoots != nil }
        tab.linkUpdating = false
        phase("locations")
        if left.password == nil && right.password == nil {
            var recents = Settings.store.dictionary(forKey: "compare.recents") as? [String: [String]] ?? [:]
            let previous = recents[left.absoluteString] ?? []
            recents[left.absoluteString] = Array(([right.absoluteString] + previous.filter { $0 != right.absoluteString }).prefix(5))
            Settings.store.set(recents, forKey: "compare.recents")
        }
        let model = CompareModel(left: left, right: right, options: options)
        model.sortRole = tab.active.model.props.sortRole
        model.sortAscending = tab.active.model.props.sortOrder == .ascending
        model.sortSide = tab.activeIsSecondary ? .right : .left
        phase("recentsAndModel")
        let comparison = tab.comparisonView(model: model)
        comparison.document.activeSide = tab.activeIsSecondary ? .right : .left
        phase("viewConstruction")
        comparison.onClose = { [weak self] in self?.stopComparing() }
        comparison.onSync = { [weak self, weak comparison] in
            guard let self, let comparison else { return }
            NotificationCenter.default.post(
                name: Notification.Name("PorpoiseCompareSyncRequested"), object: self.window,
                userInfo: [
                    "left": model.leftRoot, "right": model.rightRoot, "options": model.options,
                    "comparison": model.comparison as Any, "overrides": model.overrides,
                    "filter": model.filter.rawValue, "selection": comparison.document.selectedPath as Any,
                    "scroll": comparison.scroll.contentView.bounds.origin,
                ])
        }
        comparison.onChoose = { [weak self] in self?.chooseCompareFolder() }
        comparison.onIgnore = { [weak self, weak model] in self?.editComparisonExclusions(model) }
        comparison.onCompareFiles = { [weak self] row in
            NotificationCenter.default.post(
                name: Notification.Name("PorpoiseCompareFilesRequested"), object: self?.window,
                userInfo: [
                    "left": model.leftRoot.appendingPathComponent(row.left?.path ?? row.path),
                    "right": model.rightRoot.appendingPathComponent(row.right?.path ?? row.path),
                ])
        }
        comparison.document.onOpen = { [weak self] row in self?.openComparisonRow(row) }
        comparison.document.onCopy = { [weak self] row, side in self?.copyComparisonRow(row, from: side) }
        comparison.document.onSelection = { [weak self] _, side in
            guard let self else { return }; self.tab.setActive(secondary: side == .right); self.syncToActiveView()
        }
        // Reuse the browse row positions for the incoming glide, without changing either browse model's layout.
        let list = tab.primary.list
        if list.frames.count == list.model.rows.count {
            for index in list.candidateIndexes(in: list.visibleRect) {
                let item = list.model.rows[index].item
                if let path = LinkedBrowsing.relativePath(item.url, below: left) { comparison.document.entryOrigins[path] = list.frames[index].minY }
            }
        }
        tab.installComparison(comparison)
        phase("install")
        comparison.animateIn()
        syncToActiveView(); window?.makeFirstResponder(comparison.document); model.start()
        phase("chromeAndScanStart")
        DebugBridge.shared.compareEntryPhases = phases
    }
    func stopComparing(keepLinked: Bool = false) {
        let selectedTab = tab
        // Remove immediately: an animated exit must not race a second toggle or a queued navigation refresh.
        selectedTab.installComparison(nil)
        selectedTab.compareChooser?.removeFromSuperview(); selectedTab.compareChooser = nil
        selectedTab.missingCounterpart?.removeFromSuperview(); selectedTab.missingCounterpart = nil
        selectedTab.linkGeneration += 1; selectedTab.linkUpdating = true
        for (container, snapshot) in selectedTab.comparisonSnapshots { container.restoreComparison(snapshot) }
        selectedTab.comparisonSnapshots = []
        selectedTab.setActive(secondary: selectedTab.comparisonWasSecondary)
        if !keepLinked { selectedTab.linkedRoots = selectedTab.comparisonPreviousLinks }
        selectedTab.containers.forEach { $0.preservesMissingLocation = selectedTab.linkedRoots != nil }
        selectedTab.linkUpdating = false
        syncToActiveView(); window?.makeFirstResponder(view.list)
    }
    private func showCompareChooser() {
        let tab = tab
        if !tab.isSplit { tab.openSplit(animated: true); tab.secondary?.delegate = self }
        tab.installComparison(nil)
        let chooser = ComparePanePlaceholder()
        chooser.content.configure(
            symbol: "folder.badge.questionmark", title: "Compare \(tab.primary.url.lastPathComponent) with…",
            detail: "", button: "Choose Folder…"
        ) { [weak self] in self?.chooseCompareFolder() }
        let recentStrings = (Settings.store.dictionary(forKey: "compare.recents") as? [String: [String]])?[tab.primary.url.absoluteString] ?? []
        chooser.setRecents(recentStrings.compactMap(URL.init(string:))) { [weak self] url in
            guard let self else { return }; self.startComparing(left: self.tab.primary.url, right: url)
        }
        chooser.content.onDrop = { [weak self] url in self?.startComparing(left: self?.tab.primary.url ?? url, right: url) }
        tab.compareChooser?.removeFromSuperview(); tab.compareChooser = chooser; tab.addSubview(chooser); tab.needsLayout = true
        syncToActiveView()
        window?.makeFirstResponder(chooser)
    }
    func chooseCompareFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Compare"; panel.message = "Compare \(tab.primary.url.lastPathComponent) with…"
        panel.directoryURL = tab.lastComparePartner ?? tab.primary.url.deletingLastPathComponent()
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.startComparing(left: self.tab.primary.url, right: url)
        }
    }
    @objc func compareFolderSelection(_ sender: Any?) {
        let folders = view.model.selectedItems.filter { $0.isDirectory && !$0.isSymlink }
        if folders.count == 2 {
            startComparing(left: folders[0].url, right: folders[1].url)
        } else if let folder = folders.first {
            startComparing(left: folder.url, right: tab.inactive?.url ?? tab.primary.url)
        } else {
            toggleCompare(sender)
        }
    }
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
    func comparisonNavigationChanged(_ container: ViewContainer) {
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
                        other.setURL(target)
                    }
                    tab.linkUpdating = false
                }
            } else {
                // An unrelated path edit starts a new pair at the two visible locations.
                tab.linkedRoots = (tab.primary.url, tab.secondary!.url)
            }
        }
        if let comparison = tab.compareView {
            comparison.model.navigate(left: tab.primary.url, right: tab.secondary!.url)
            comparison.scroll.contentView.scroll(to: .zero)
        }
        tab.missingCounterpart?.removeFromSuperview(); tab.missingCounterpart = nil
        guard tab.linkedRoots != nil, tab.compareView == nil else { return }
        let target = other.url
        DispatchQueue.global(qos: .utility).async { [weak self, weak tab, weak other] in
            let exists: Bool
            if let provider = RemoteFS.provider(for: target) {
                exists = (try? provider.list(target)) != nil
            } else {
                var directory: ObjCBool = false
                exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &directory) && directory.boolValue
            }
            DispatchQueue.main.async {
                guard let self, let tab, let other, tab.linkGeneration == generation, tab.linkedRoots != nil, tab.compareView == nil, !exists else {
                    return
                }
                let placeholder = ComparePanePlaceholder()
                placeholder.content.configure(
                    symbol: "folder.badge.questionmark", title: "No “\(target.lastPathComponent)” on this side",
                    detail: "Go back or up to continue browsing both folders.", button: "Create Folder"
                ) { [weak self] in self?.createLinkedCounterpart(target) }
                placeholder.unlink.isHidden = false; placeholder.unlink.clicked = { [weak self] in self?.toggleLinkedBrowsing(nil) }
                tab.missingCounterpart = placeholder; tab.missingOnRight = other === tab.secondary
                tab.addSubview(placeholder); tab.needsLayout = true; self.syncToActiveView()
            }
        }
    }
    private func createLinkedCounterpart(_ url: URL) {
        let selectedTab = tab
        DispatchQueue.global(qos: .utility).async { [weak self, weak selectedTab] in
            let result = Result {
                if let provider = RemoteFS.provider(for: url) {
                    try provider.makeFolder(url)
                } else {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }
            }
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
    private func openComparisonRow(_ row: SyncDifference) {
        guard let compare = tab.compareView else { return }
        if (row.left ?? row.right)?.kind == .directory {
            let preferred = compare.document.activeSide
            let side: SyncSide = (preferred == .left ? row.left : row.right) != nil ? preferred : preferred.opposite
            let container = side == .left ? tab.primary : tab.secondary!
            container.setURL(
                (side == .left ? compare.model.leftRoot : compare.model.rightRoot).appendingPathComponent(
                    (side == .left ? row.left : row.right)!.path))
        } else if let entry = compare.document.activeSide == .left ? row.left : row.right {
            let url = (compare.document.activeSide == .left ? compare.model.leftRoot : compare.model.rightRoot).appendingPathComponent(entry.path)
            if url.isFileURL { NSWorkspace.shared.open(url) }
        }
    }
    func copyComparisonRow(_ row: SyncDifference, from side: SyncSide) {
        guard let compare = tab.compareView, let entry = side == .left ? row.left : row.right else { return }
        let source = (side == .left ? compare.model.leftRoot : compare.model.rightRoot).appendingPathComponent(entry.path)
        let targetRoot = side == .left ? compare.model.rightRoot : compare.model.leftRoot
        let destination = targetRoot.appendingPathComponent((row.path as NSString).deletingLastPathComponent)
        FileOperationsController.shared.run(.copy, [source], to: destination, window: window, done: { [weak compare] _ in compare?.model.start() })
    }
    private func editComparisonExclusions(_ model: CompareModel?) {
        guard let model, let window else { return }
        let alert = NSAlert(); alert.messageText = "Ignore files and folders";
        alert.informativeText = "One pattern per line. Matching folders and their contents are ignored."
        let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 380, height: 120)); field.string = model.options.exclusions.joined(separator: "\n")
        alert.accessoryView = field; alert.addButton(withTitle: "Compare"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            model.options.exclusions = field.string.components(separatedBy: .newlines).filter { !$0.isEmpty }; model.start()
        }
    }
    @objc func showSameComparisonItems(_ sender: Any?) { tab.compareView?.model.toggle(.same) }
    @objc func nextComparisonDifference(_ sender: Any?) { tab.compareView?.document.difference(forward: true) }
    @objc func previousComparisonDifference(_ sender: Any?) { tab.compareView?.document.difference(forward: false) }
    @objc func syncComparison(_ sender: Any?) { tab.compareView?.onSync?() }
}
