import Foundation
import PorpoiseCore

/// What the signed-in user may do with a cloud item or folder (Google Drive's per-item capabilities).
public struct CloudPermissions: Equatable, Sendable {
    public var canAddChildren: Bool
    public var canRename: Bool
    public var canTrash: Bool
    /// Within the same account (cut and paste, drag).
    public var canMove: Bool
    public var canCopy: Bool
    public var access: CloudItemInfo.Access?
    /// Shared with me and Shared drives are lists of items, not folders: nothing goes in them.
    public var collection: CloudRoot?
    public var inSharedDrive: Bool
    public var name: String?

    public init(
        canAddChildren: Bool = false, canRename: Bool = false, canTrash: Bool = false, canMove: Bool = false, canCopy: Bool = true,
        access: CloudItemInfo.Access? = nil, collection: CloudRoot? = nil, inSharedDrive: Bool = false, name: String? = nil
    ) {
        self.canAddChildren = canAddChildren
        self.canRename = canRename
        self.canTrash = canTrash
        self.canMove = canMove
        self.canCopy = canCopy
        self.access = access
        self.collection = collection
        self.inSharedDrive = inSharedDrive
        self.name = name
    }

    /// Everything an owner may do.
    public static func owner(_ name: String? = nil) -> CloudPermissions {
        CloudPermissions(canAddChildren: true, canRename: true, canTrash: true, canMove: true, access: .owner, name: name)
    }

    /// Why `action` isn't possible, in the user's words; nil when it is.
    public func denial(_ action: CloudAction) -> String? {
        let what = name.map { "“\($0)”" } ?? "this item"
        let readOnly: String? = {
            switch access {
            case .viewer: return "You have view-only access to \(what)."
            case .commenter: return "You can only comment on \(what)."
            default: return nil
            }
        }()
        switch action {
        case .addItems:
            if canAddChildren { return nil }
            switch collection {
            case .sharedWithMe: return "Shared with me lists what others shared with you. Open one of its folders to add items there."
            case .sharedDrives: return "Open a shared drive to add items to it."
            case .myDrive, nil: break
            }
            return readOnly ?? "You can’t add items to \(name.map { "“\($0)”" } ?? "this folder")."
        case .rename:
            if canRename { return nil }
            return readOnly ?? "You can’t rename \(what)."
        case .trash:
            if canTrash { return nil }
            if let readOnly { return readOnly }
            return inSharedDrive
                ? "Only managers of this shared drive can move \(what) to the Trash."
                : "Only the owner can move \(what) to the Trash."
        case .move:
            if canMove { return nil }
            if let readOnly { return readOnly }
            return inSharedDrive ? "Only managers of this shared drive can move \(what)." : "Only the owner can move \(what)."
        case .copy:
            if canCopy { return nil }
            return "The owner of \(what) turned off copying and downloading."
        }
    }
}

/// Things that change a cloud location, each gated by permissions.
public enum CloudAction: Sendable, CaseIterable {
    /// New Folder, paste or drop into a folder.
    case addItems
    case rename, trash
    /// Taking items out of their folder (cut, drag-move).
    case move
    /// Copying items out (copy, drag-copy, download).
    case copy
}

/// A failed change, as the message bar says it.
public enum CloudEditError: LocalizedError, Equatable {
    case denied(String)
    case notSupported

    public var errorDescription: String? {
        switch self {
        case .denied(let why): return why
        case .notSupported: return "This account can’t be changed from Porpoise yet."
        }
    }
}

// Services that can't change anything yet (and the demo before tests set it up).
extension CloudBackend {
    public func permissions(for url: URL) -> CloudPermissions? { nil }
    public func requestWriteAccess(
        _ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void
    ) -> () -> Void {
        signInAgain(id, openBrowser: openBrowser, done: done)
    }
    public func createFolder(named name: String, in folder: URL, done: @escaping (Result<FileItem, Error>) -> Void) {
        done(.failure(CloudEditError.notSupported))
    }
    public func rename(_ url: URL, to name: String, done: @escaping (Result<FileItem, Error>) -> Void) {
        done(.failure(CloudEditError.notSupported))
    }
    public func trash(_ urls: [URL], done: @escaping (_ trashed: [URL], _ error: Error?) -> Void) { done([], CloudEditError.notSupported) }
    public func untrash(_ urls: [URL], done: @escaping (_ restored: [URL], _ error: Error?) -> Void) {
        done([], CloudEditError.notSupported)
    }
}

/// Changing cloud locations: permission checks with the reason for the tooltip, the changes themselves with Undo.
extension CloudAccounts {
    public func permissions(for url: URL) -> CloudPermissions? { backend?.permissions(for: url) }

    /// The account-wide reason nothing can be changed (offline, signed out, connected read-only); nil: changes can be tried.
    public func accountDenial(for url: URL) -> String? {
        guard PlacesModel.isCloud(url) else { return nil }
        guard let a = account(for: url) else { return "The account this folder belongs to isn’t connected." }
        switch a.status {
        case .offline: return "You’re offline. Changes to \(a.provider.title) need a connection."
        case .signInNeeded: return "Sign in to \(a.provider.title) again to make changes."
        case .ok: break
        }
        return a.canWrite ? nil : "Allow Porpoise to make changes to \(a.provider.title) first."
    }

    /// Why `action` can't be done: on `items` (rename, trash, move, copy), or in `folder` (adding items); nil when it can,
    /// or when the service hasn't said (it then decides, and a refusal rolls the change back).
    public func denial(_ action: CloudAction, items: [URL] = [], folder: URL? = nil) -> String? {
        let targets = action == .addItems ? [folder].compactMap { $0 } : items
        guard let first = targets.first(where: PlacesModel.isCloud) else { return nil }
        // Copying out works whatever the sign-in allows.
        if action != .copy, let why = accountDenial(for: first) { return why }
        for u in targets where PlacesModel.isCloud(u) {
            if let why = permissions(for: u)?.denial(action) { return why }
        }
        return nil
    }

    /// The account's provider name ("Google Drive"), for messages.
    public func providerTitle(for url: URL) -> String { account(for: url)?.provider.title ?? "the cloud" }

    /// "Moved “Budget” to Google Drive Trash" / "Moved 3 items to Google Drive Trash".
    public func trashMessage(_ urls: [URL], names: [URL: String]) -> String {
        let place = providerTitle(for: urls.first ?? URL(fileURLWithPath: "/")) + " Trash"
        if urls.count == 1, let n = names[urls[0]] { return "Moved “\(n)” to \(place)" }
        return "Moved \(urls.count) item\(urls.count == 1 ? "" : "s") to \(place)"
    }

    // MARK: Changes (answers on the main queue)

    /// Asks for permission to make changes (only the browser step); the account keeps its places.
    public func requestWriteAccess(_ id: String, openBrowser: @escaping (URL) -> Void, done: @escaping (Result<Void, CloudConnectError>) -> Void)
        -> () -> Void
    {
        guard let backend else { done(.failure(.failed("Not connected."))); return {} }
        return backend.requestWriteAccess(id, openBrowser: openBrowser, done: done)
    }

    public func createFolder(named name: String, in folder: URL, done: @escaping (Result<FileItem, Error>) -> Void) {
        if let why = denial(.addItems, folder: folder) { done(.failure(CloudEditError.denied(why))); return }
        guard let backend else { done(.failure(CloudEditError.notSupported)); return }
        backend.createFolder(named: name, in: folder) { result in
            if case .success(let item) = result {
                FileOperationsController.shared.pushUndo(.cloud(CloudChange(.appeared, [item.url], label: "New Folder")))
            }
            done(result)
        }
    }

    public func rename(_ url: URL, from old: String, to name: String, done: @escaping (Result<FileItem, Error>) -> Void) {
        if let why = denial(.rename, items: [url]) { done(.failure(CloudEditError.denied(why))); return }
        guard let backend else { done(.failure(CloudEditError.notSupported)); return }
        backend.rename(url, to: name) { result in
            if case .success = result {
                FileOperationsController.shared.pushUndo(.cloud(CloudChange(.renamed(from: old, to: name), [url], label: "Rename")))
            }
            done(result)
        }
    }

    /// Into the service's trash, never deleted; Undo restores them.
    public func trash(_ urls: [URL], done: @escaping (_ trashed: [URL], _ error: Error?) -> Void) {
        if let why = denial(.trash, items: urls) { done([], CloudEditError.denied(why)); return }
        guard let backend else { done([], CloudEditError.notSupported); return }
        backend.trash(urls) { trashed, error in
            if !trashed.isEmpty {
                FileOperationsController.shared.pushUndo(.cloud(CloudChange(.trashed, trashed, label: "Move to Trash")))
            }
            done(trashed, error)
        }
    }

    /// Undo and Redo of a change, through the service.
    public func revert(_ change: CloudChange, done: @escaping (Error?) -> Void) {
        guard let backend else { done(CloudEditError.notSupported); return }
        switch change.kind {
        case .trashed:
            backend.untrash(change.urls) { _, error in done(error) }
        case .appeared:
            backend.trash(change.urls) { _, error in done(error) }
        case .renamed(let from, _):
            guard let url = change.urls.first else { done(nil); return }
            backend.rename(url, to: from) { result in
                if case .failure(let error) = result { done(error) } else { done(nil) }
            }
        }
    }

    /// Restores items from the service's trash (the message bar's Undo, which also takes the record off the Undo stack).
    public func untrash(_ urls: [URL], done: @escaping (_ restored: [URL], _ error: Error?) -> Void) {
        guard let backend else { done([], CloudEditError.notSupported); return }
        FileOperationsController.shared.dropCloudUndo(CloudChange(.trashed, urls, label: "Move to Trash"))
        backend.untrash(urls, done: done)
    }
}

extension FileOperationsController {
    /// Undone some other way (the message bar's Undo): the record mustn't be undone twice.
    func dropCloudUndo(_ change: CloudChange) {
        guard case .cloud(let last)? = undoStack.last, Set(last.urls) == Set(change.urls), last.kind == change.kind else { return }
        undoStack.removeLast()
        NotificationCenter.default.post(name: Self.undoChanged, object: nil)
    }
}
