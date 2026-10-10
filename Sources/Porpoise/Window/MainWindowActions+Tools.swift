import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz

extension MainWindowController {
    // MARK: Tools

    /// Local folders "Open Terminal" acts on: the selected folders, else the current one.
    var terminalFolders: [URL] {
        let sel = view.model.selectedItems.filter(\.isBrowsableFolder)
        return (sel.isEmpty ? [view.url] : sel.map(\.url)).filter(\.isFileURL)
    }

    /// Tools › Open Terminal (⇧F4): a terminal in the current folder, whatever is selected.
    @objc func openTerminal(_ sender: Any?) {
        guard view.url.isFileURL else { return }
        ExternalTerminal.open(at: view.url)
    }

    /// Open Terminal Here (⌥⇧F4, context menus): one terminal per selected folder, else the current folder.
    @objc func openTerminalHere(_ sender: Any?) {
        let dirs = terminalFolders
        guard !dirs.isEmpty else { return }
        guard dirs.count > 3 && Settings.shared.confirmManyTerminals else { dirs.forEach(ExternalTerminal.open(at:)); return }
        let a = NSAlert()
        a.messageText = "Are you sure you want to open \(dirs.count) terminals?"
        a.addButton(withTitle: "Open Terminals")
        a.addButton(withTitle: "Cancel")
        a.runSheet(for: window) { r in if r == .alertFirstButtonReturn { dirs.forEach(ExternalTerminal.open(at:)) } }
    }

    @objc func quickLook(_ sender: Any?) {
        guard let p = QLPreviewPanel.shared() else { return }
        if p.isVisible { p.orderOut(nil) } else { p.makeKeyAndOrderFront(nil) }
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = actionTargets.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func emptyTrash(_ sender: Any?) { FileOperationsController.shared.emptyTrash(window: window) }

    @objc func shareItems(_ sender: Any?) {
        let urls = selectedURLs.filter(\.isFileURL)
        guard let first = urls.first else { return }
        let picker = NSSharingServicePicker(items: urls)
        let r = view.list.rect(for: first) ?? view.list.visibleRect
        picker.show(relativeTo: r, of: view.list, preferredEdge: .maxY)
    }

    @objc func setTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        toggleTag(tag)
    }

    static func tagNames(of url: URL) -> [String] { (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [] }

    /// Adds the tag to every selected item, or removes it if they all have it (Finder).
    func toggleTag(_ tag: String) {
        let urls = selectedURLs.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        let all = urls.allSatisfy { Self.tagNames(of: $0).contains(tag) }
        for u in urls {
            var tags = Self.tagNames(of: u)
            tags.removeAll { $0 == tag }
            if !all { tags.append(tag) }
            try? (u as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        view.model.refreshTags()
        view.list.needsDisplay = true
    }

    @objc func cloudDownload(_ sender: Any?) { CloudActions.download(selectedURLs) }
    @objc func cloudEvict(_ sender: Any?) {
        let failed = CloudActions.evict(selectedURLs)
        guard !failed.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Some downloads could not be removed."
        a.informativeText = failed.prefix(6).joined(separator: "\n")
        a.window.appearance = NSAppearance(named: .darkAqua)
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    /// Zips the selection next to it: "<name>.zip" for one item, "Archive.zip" for several.
    @objc func compress(_ sender: Any?) {
        let urls = selectedURLs.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        let folder = Self.commonFolder(of: urls)
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var zipName = "\(base).zip"
        var n = 2
        while existing.contains(zipName) { zipName = "\(base) \(n).zip"; n += 1 }
        let zip = folder.appendingPathComponent(zipName)
        let p = Process()
        p.currentDirectoryURL = folder
        if urls.count == 1 {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, zip.path]
        } else {
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            // "./name": names starting with "-" must not be read as zip options.
            p.arguments = ["-r", "-q", "./" + zipName] + urls.map { "./" + String($0.path.dropFirst(prefix.count)) }
        }
        runTool(p, failure: "Could not create “\(zipName)”.", select: zip)
    }

    /// Unpacks the selected archive into a new folder next to it, named after it ("<name>", "<name> 2"…), so
    /// nothing already there is ever overwritten (Ark's "Extract here, autodetect subfolder" without the guessing).
    @objc func extractHere(_ sender: Any?) {
        guard let it = view.model.selectedItems.first, it.url.isFileURL else { return }
        let parent = it.url.deletingLastPathComponent()
        var base = it.url.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }   // name.tar.gz
        if base.isEmpty { base = "Archive" }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
        var name = base
        var n = 2
        while existing.contains(name) { name = "\(base) \(n)"; n += 1 }
        let dest = parent.appendingPathComponent(name, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false) } catch {
            reportError("Could not extract “\(it.name)”: \(error.localizedDescription)"); return
        }
        let p = Process()
        if it.fileExtension.lowercased() == "zip" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", it.url.path, dest.path]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xf", it.url.path, "-C", dest.path]
        }
        // A failed extraction leaves no empty folder behind (a partial one is kept: it may hold what could be read).
        runTool(p, failure: "Could not extract “\(it.name)”.", select: dest) {
            if ((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? ["?"]).isEmpty { try? FileManager.default.removeItem(at: dest) }
        }
    }

    /// Deepest folder containing all `urls` (their shared parent in the usual case).
    static func commonFolder(of urls: [URL]) -> URL {
        var parts = urls[0].deletingLastPathComponent().standardizedFileURL.pathComponents
        for u in urls.dropFirst() {
            let other = u.deletingLastPathComponent().standardizedFileURL.pathComponents
            parts = Array(zip(parts, other).prefix { $0 == $1 }.map(\.0))
        }
        return URL(fileURLWithPath: NSString.path(withComponents: parts.isEmpty ? ["/"] : parts), isDirectory: true)
    }

    /// Runs an archiver in the background, then reloads the view (and reports failures).
    private func runTool(_ p: Process, failure: String, select: URL?, onFailure: (() -> Void)? = nil) {
        let c = view
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if proc.terminationStatus != 0 { onFailure?(); self?.reportError(failure, in: c) } else if let select { c.pendingSelect = select }
                c.reload()
            }
        }
        do { try p.run() } catch { onFailure?(); reportError("\(failure) \(error.localizedDescription)", in: c) }
    }
}
