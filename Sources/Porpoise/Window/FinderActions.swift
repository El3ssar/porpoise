import AppKit
import PorpoiseCore
import PorpoiseServices

/// Finder features beyond Dolphin's own (so the app can stand in for Finder): Finder's Go shortcuts,
/// aliases, eject, package contents, desktop picture, folder-with-selection, deselect.
extension MainWindowController {

    private var selection: [FileItem] { view.model.selectedItems }

    // MARK: Go (Finder's ⌘⇧ letters)

    static let goTargets: [(title: String, key: String, mods: NSEvent.ModifierFlags, icon: String, url: () -> URL?)] = [
        ("Recents", "f", [.command, .shift], "document-open-recent", { PlacesModel.recentFilesURL }),
        ("Documents", "o", [.command, .shift], "folder-documents", { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }),
        ("Desktop", "d", [.command, .shift], "user-desktop", { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first }),
        ("Downloads", "l", [.command, .option], "folder-download", { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }),
        ("Computer", "c", [.command, .shift], "computer", { URL(fileURLWithPath: "/Volumes") }),
        ("Applications", "a", [.command, .shift], "folder-applications", { URL(fileURLWithPath: "/Applications") }),
        ("Utilities", "u", [.command, .shift], "applications-utilities", { URL(fileURLWithPath: "/Applications/Utilities") }),
        ("iCloud Drive", "i", [.command, .shift], "folder-cloud", {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        }),
        ("Library", "l", [.command, .shift], "folder-library", { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library") }),
    ]

    @objc func goToTarget(_ sender: NSMenuItem) {
        guard let t = Self.goTargets[safe: sender.tag], let u = t.url() else { return }
        view.setURL(u)
        window?.makeFirstResponder(view.list)
    }

    @objc func goAirDrop(_ sender: Any?) {
        let airdrop = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
        let files = selection.map(\.url).filter(\.isFileURL)
        if !files.isEmpty, let s = NSSharingService(named: .sendViaAirDrop) { s.perform(withItems: files) }
        else { NSWorkspace.shared.open(airdrop) }
    }

    /// Finder's Go to Folder (⌘⇧G): the editable location bar with its path selected.
    @objc func goToFolder(_ sender: Any?) { replaceLocation(sender) }

    // MARK: Items

    /// Finder alias (bookmark file) next to each selected item, named "<name> alias".
    @objc func makeAlias(_ sender: Any?) {
        var made: [URL] = []
        for it in selection where it.url.isFileURL {
            var dst = it.url.deletingLastPathComponent().appendingPathComponent(it.name + " alias")
            var n = 2
            while FileManager.default.fileExists(atPath: dst.path) {
                dst = it.url.deletingLastPathComponent().appendingPathComponent("\(it.name) alias \(n)"); n += 1
            }
            do {
                let data = try it.url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: dst)
                made.append(dst)
            } catch {
                reportError("Could not make an alias of “\(it.name)”: \(error.localizedDescription)")
            }
        }
        if !made.isEmpty {
            FileOperationsController.shared.pushUndo(.created(made))
            view.pendingSelect = made.last
            view.reload()
        }
    }

    /// Show Original (⌘R): the target of a symlink or Finder alias, selected in its folder.
    @objc func showOriginal(_ sender: Any?) {
        guard let it = selection.first, let target = Self.resolvedTarget(of: it) else { return }
        view.setURL(target.deletingLastPathComponent(), selecting: target)
    }

    static func isAlias(_ it: FileItem) -> Bool {
        it.url.isFileURL && !it.isSymlink && ((try? it.url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) ?? false)
    }

    static func resolvedTarget(of it: FileItem) -> URL? {
        if isAlias(it) { return try? URL(resolvingAliasFileAt: it.url, options: [.withoutUI]) }
        if it.isSymlink { return it.url.resolvingSymlinksInPath() }
        return nil
    }

    /// Eject (⌘E): the selected volumes, or the volume of the current folder.
    @objc func ejectVolume(_ sender: Any?) {
        let targets = selection.isEmpty ? [view.url] : selection.map(\.url)
        var vols = Set<URL>()
        for u in targets {
            guard let v = try? u.resourceValues(forKeys: [.volumeURLKey]).volume,
                  let rv = try? v.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey]) else { continue }
            let ejectable: Bool = rv.volumeIsEjectable == true || rv.volumeIsRemovable == true || rv.volumeIsLocal == false
            if ejectable { vols.insert(v) }
        }
        guard !vols.isEmpty else { NSSound.beep(); return }
        // Every view showing it (other tabs, panes and windows too) leaves the volume first, or it is busy.
        vols.forEach(Self.leaveVolume)
        for v in vols {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: v) } catch {
                    DispatchQueue.main.async {
                        self?.reportError("“\(v.lastPathComponent)” could not be ejected: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Open (⌘O / ⌘↓): the selected items, like double-clicking them.
    @objc func openSelected(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        container(view, open: selection, inNewTab: false)
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let it = selection.first, it.isDirectory else { return }
        view.setURL(it.url)
    }

    @objc func setDesktopPicture(_ sender: Any?) {
        guard let it = selection.first, it.url.isFileURL else { return }
        for s in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(it.url, for: s, options: [:]) }
    }

    /// New Folder with Selection (⌃⌘N).
    @objc func newFolderWithSelection(_ sender: Any?) {
        let items = selection.filter { $0.url.isFileURL }
        guard !items.isEmpty else { return }
        let parent = view.url
        var folder = parent.appendingPathComponent("New Folder With Items")
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) { folder = parent.appendingPathComponent("New Folder With Items \(n)"); n += 1 }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) } catch {
            reportError(error.localizedDescription); return
        }
        FileOperationsController.shared.run(.move, items.map(\.url), to: folder, window: window) { [weak self] _ in
            guard let self else { return }
            self.view.pendingSelect = folder
            self.view.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.view.list.beginRename(folder) }
        }
    }

    @objc func deselectAll(_ sender: Any?) {
        view.model.selection = []
        view.list.needsDisplay = true
    }

    // MARK: Validation for the actions above

    func validateFinderItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(makeAlias(_:)):
            // Aliases go next to their originals, so this works in search results and Recents too.
            return selection.contains { $0.url.isFileURL }
        case #selector(newFolderWithSelection(_:)):
            return view.url.isFileURL && selection.contains { $0.url.isFileURL }
        case #selector(showOriginal(_:)):
            return selection.first.map { $0.isSymlink || Self.isAlias($0) } ?? false
        case #selector(showPackageContents(_:)):
            return selection.count == 1 && selection[0].isPackage
        case #selector(setDesktopPicture(_:)):
            return selection.count == 1 && selection[0].url.isFileURL && selection[0].utType?.conforms(to: .image) == true
        case #selector(deselectAll(_:)), #selector(openSelected(_:)): return !selection.isEmpty
        case #selector(ejectVolume(_:)): return view.url.isFileURL
        default: return nil
        }
    }
}
