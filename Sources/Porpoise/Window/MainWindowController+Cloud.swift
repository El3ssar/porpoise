import AppKit
import PorpoiseCore
import PorpoiseServices

/// A change shown at once in every view of a cloud folder (all windows, tabs and panes), until the service answers.
final class CloudEdit {
    private var shown: [(view: Weak<ViewContainer>, id: UUID)] = []

    init(_ edit: ListingEdit) {
        for c in Self.cloudViews { shown.append((Weak(c), c.model.applyEdit(edit))) }
    }

    /// The service answered: keep the change, or put things back.
    func end(rollback: Bool) {
        for s in shown { s.view.value?.model.endEdit(s.id, rollback: rollback) }
        shown = []
    }

    /// A one-off change everywhere (the service's own version of an optimistic row).
    static func apply(_ edit: ListingEdit) { cloudViews.forEach { $0.model.apply(edit) } }

    /// Views showing a cloud folder.
    static var cloudViews: [ViewContainer] {
        AppDelegate.shared.windows.flatMap(\.allContainers).filter { PlacesModel.isCloud($0.model.location) }
    }

    /// Items with these URLs, as the views list them.
    static func items(_ urls: [URL]) -> [FileItem] {
        let wanted = Set(urls)
        var seen: Set<URL> = []
        return cloudViews.flatMap { $0.model.rows.map(\.item) }.filter { wanted.contains($0.url) && seen.insert($0.url).inserted }
    }
}

struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Changing Google Drive like a local disk: rows appear, rename or vanish at once and keep the selection; the service
/// confirms, or the change rolls back with a calm message. Trash is Drive's own, with Undo.
extension MainWindowController {
    /// Something in a cloud folder couldn't be done: the reason in the message bar, never an alert.
    func cloudFailed(_ what: String, _ error: Error, in c: ViewContainer) {
        if (error as? CloudEditError) == .needsWriteAccess { c.showWriteAccessBanner(); return }
        let why = error.localizedDescription
        c.messageBar.show(why.isEmpty ? what : "\(what) \(why)", error: true)
        c.needsLayout = true
    }

    /// An action the user can't take here (the menu item would have said why): say it in the message bar.
    func cloudDenied(_ why: String, in c: ViewContainer) {
        if CloudAccounts.shared.account(for: c.url)?.canWrite == false {
            c.showWriteAccessBanner()
            return
        }
        c.messageBar.show(why, error: false)
        c.needsLayout = true
    }

    func createCloudFolder() {
        let c = view
        let folder = c.url
        if let why = CloudAccounts.shared.denial(.addItems, folder: folder) { cloudDenied(why, in: c); return }
        NewItemDialog.runCloud(in: folder, title: folder.folderName, names: Set(c.model.items.map(\.name)), window: window) {
            [weak self] name in self?.createCloudFolder(named: name, in: c)
        }
    }

    /// The folder shows at once, selected; the service's answer replaces it with the real one, or takes it away.
    func createCloudFolder(named name: String, in c: ViewContainer? = nil) {
        let c = c ?? view
        let folder = c.url
        let temp = FileItem(
            url: folder.appendingPathComponent("new-\(UUID().uuidString)", isDirectory: true), name: name, isDirectory: true,
            modificationDate: Date(), contentType: "public.folder", owner: "me")
        let edit = CloudEdit(ListingEdit(folder: folder, added: [temp]))
        c.list.select(temp.url)
        CloudAccounts.shared.createFolder(named: name, in: folder) { [weak self] result in
            let selected = c.model.selection.contains(temp.url)
            edit.end(rollback: true)
            switch result {
            case .success(let item):
                CloudEdit.apply(ListingEdit(folder: folder, added: [item]))
                if selected { c.list.select(item.url) }
            case .failure(let error):
                self?.cloudFailed("Couldn’t create “\(name)”.", error, in: c)
            }
        }
    }

    /// Inline rename: the new name shows at once; a refusal puts the old one back.
    func renameCloud(_ item: FileItem, to name: String, in c: ViewContainer) {
        if let why = CloudAccounts.shared.denial(.rename, items: [item.url]) { cloudDenied(why, in: c); return }
        let edit = CloudEdit(ListingEdit(folder: item.url.deletingLastPathComponent(), replaced: [item.named(name)]))
        CloudAccounts.shared.rename(item.url, from: item.name, to: name) { [weak self] result in
            switch result {
            case .success(let renamed):
                edit.end(rollback: false)
                CloudEdit.apply(ListingEdit(folder: renamed.url.deletingLastPathComponent(), replaced: [renamed]))
            case .failure(let error):
                edit.end(rollback: true)
                self?.cloudFailed("Couldn’t rename “\(item.name)”.", error, in: c)
            }
        }
    }

    /// Into Google Drive's Trash: the rows go at once, the message bar offers Undo. Never a "delete permanently" question.
    func trashCloud(_ urls: [URL], confirmed: Bool = false) {
        if !confirmed, !CloudAccounts.shared.supportsTrashUndo(urls) {
            let alert = NSAlert()
            alert.messageText = "Delete these items from \(urls.first.map { CloudAccounts.shared.providerTitle(for: $0) } ?? "the cloud")?"
            alert.informativeText = "Porpoise cannot undo this deletion automatically. Recovery, when available, is through the service’s website."
            alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                if response == .alertFirstButtonReturn { self?.trashCloud(urls, confirmed: true) }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
            return
        }
        let c =
            view.model.rows.contains { urls.contains($0.item.url) }
            ? view : (allContainers.first { $0.model.rows.contains { urls.contains($0.item.url) } } ?? view)
        if let why = CloudAccounts.shared.denial(.trash, items: urls) { cloudDenied(why, in: c); return }
        let originals = CloudEdit.items(urls)
        let names = Dictionary(originals.map { ($0.url, $0.name) }, uniquingKeysWith: { a, _ in a })
        let folder = c.url
        if c.list.isRenaming { c.list.cancelRename() }
        let edit = CloudEdit(ListingEdit(folder: folder, removed: Set(urls)))
        CloudAccounts.shared.trash(urls) { [weak self] trashed, error in
            edit.end(rollback: false)
            // Whatever didn't go comes back.
            let kept = originals.filter { !trashed.contains($0.url) }
            if !kept.isEmpty { CloudEdit.apply(ListingEdit(folder: folder, added: kept)) }
            if let error, trashed.isEmpty {
                let what =
                    urls.count == 1 ? "Couldn’t move “\(names[urls[0]] ?? "the item")” to the Trash." : "Couldn’t move these items to the Trash."
                self?.cloudFailed(what, error, in: c)
                return
            }
            var text = CloudAccounts.shared.trashMessage(trashed, names: names)
            if let error { text += ". \(kept.count) couldn’t be moved: \(error.localizedDescription)" }
            c.cloudTrashNotice = Set(trashed)
            if CloudAccounts.shared.supportsTrashUndo(trashed) {
                c.messageBar.show(text, error: false, action: "Undo") { [weak self] in
                    self?.undoCloudTrash(originals.filter { trashed.contains($0.url) }, folder: folder, in: c)
                }
            } else {
                c.messageBar.show(text, error: false)
            }
            c.needsLayout = true
        }
    }

    private func undoCloudTrash(_ items: [FileItem], folder: URL, in c: ViewContainer) {
        c.messageBar.dismiss()
        c.cloudTrashNotice = []
        let urls = items.map(\.url)
        let edit = CloudEdit(ListingEdit(folder: folder, added: items))
        CloudAccounts.shared.untrash(urls) { [weak self] restored, error in
            edit.end(rollback: false)
            let missing = items.filter { !restored.contains($0.url) }
            if !missing.isEmpty { CloudEdit.apply(ListingEdit(folder: folder, removed: Set(missing.map(\.url)))) }
            if let error {
                self?.cloudFailed("Couldn’t put back \(missing.count == 1 ? "“\(missing[0].name)”" : "\(missing.count) items").", error, in: c)
            }
            if restored.count == items.count { c.list.select(urls[0]); c.model.selection = Set(urls) }
        }
    }
}

// MARK: - Menus: disabled with the reason, never hidden

extension MainWindowController {
    /// Validation for editing commands that touch a cloud folder or cloud items; nil: not a cloud case. The menu item's
    /// tooltip says why it's disabled ("You have view-only access to “Q3”").
    func validateCloudItem(_ item: NSMenuItem) -> Bool? {
        let cloudSelection = selectedURLs.filter(PlacesModel.isCloud)
        let inCloud = PlacesModel.isCloud(view.url)
        guard inCloud || !cloudSelection.isEmpty else { return nil }
        let accounts = CloudAccounts.shared
        var why: String?
        switch item.action {
        case #selector(renameItem(_:)):
            guard !cloudSelection.isEmpty else { return nil }
            why = cloudSelection.count > 1 ? "Rename cloud items one at a time." : accounts.denial(.rename, items: cloudSelection)
        case #selector(moveToTrash(_:)), #selector(deleteItem(_:)):
            guard !cloudSelection.isEmpty else { return nil }
            why = accounts.denial(.trash, items: cloudSelection)
        case #selector(cut(_:)):
            guard !cloudSelection.isEmpty else { return nil }
            why = accounts.denial(.move, items: cloudSelection)
        case #selector(copy(_:)):
            guard !cloudSelection.isEmpty else { return nil }
            why = accounts.denial(.copy, items: cloudSelection)
        case #selector(createFolder(_:)):
            guard inCloud else { return nil }
            why = accounts.denial(.addItems, folder: view.url)
        case #selector(createFile(_:)), #selector(createFromTemplate(_:)):
            guard inCloud else { return nil }
            item.toolTip = "You can create folders here. To add a file, copy or drag it here."
            return false
        case #selector(paste(_:)):
            guard !FileOperationsController.shared.clipboardURLs.isEmpty else { item.toolTip = nil; return false }
            var target = view.url
            let sel = view.model.selectedItems
            if item.representedObject as? String == Self.pasteIntoFolder, sel.count == 1, sel[0].isBrowsableFolder { target = sel[0].url }
            guard PlacesModel.isCloud(target) else { return nil }
            if item.representedObject as? String != Self.pasteIntoFolder { item.title = FileOperationsController.shared.pasteTitle }
            why = accounts.denial(.addItems, folder: target)
        default:
            return nil
        }
        item.toolTip = why
        return why == nil
    }
}
