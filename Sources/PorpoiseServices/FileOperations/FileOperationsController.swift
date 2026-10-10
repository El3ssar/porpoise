import Foundation
import PorpoiseCore

/// App-wide file operations: clipboard (cut/copy/paste), jobs and their progress, undo/redo, the Trash.
/// Mirrors KIO's job tracker + FileUndoManager. Main thread only; questions and progress go through `ui`.
public final class FileOperationsController {
    public static let shared = FileOperationsController()
    public static let cutChanged = Notification.Name("PorpoiseCutChanged")
    static let undoChanged = Notification.Name("PorpoiseUndoChanged")
    /// Posted after an operation with the folders it touched (KDirNotify equivalent); views reload at once.
    public static let foldersChanged = Notification.Name("PorpoiseFoldersChanged")

    /// Posts `foldersChanged` for each URL and its parent folder.
    public static func notifyChanged(_ urls: [URL]) {
        let dirs = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path } + urls.map { $0.standardizedFileURL.path })
        NotificationCenter.default.post(name: foldersChanged, object: nil, userInfo: ["paths": dirs])
    }

    /// Dialogs and progress (set by the app; without it nothing is confirmed and conflicts cancel).
    public var ui: FileOperationsUI?
    public var clipboard: FileClipboard = LocalClipboard()

    var undoStack: [UndoRecord] = []
    var redoStack: [UndoRecord] = []
    private var cutChangeCount = -1
    public private(set) var cutURLs: Set<URL> = []

    public init() {}

    // MARK: Clipboard

    public func copy(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        clipboard.write(urls)
        cutChangeCount = cut ? clipboard.changeCount : -1
        cutURLs = cut ? Set(urls) : []
        NotificationCenter.default.post(name: Self.cutChanged, object: nil)
    }

    /// Files on the clipboard (from Porpoise, Finder or any other app), and items of remote locations
    /// Porpoise copied (sftp://, ftp://, adb://). Web links and other URLs are not files to paste.
    public var clipboardURLs: [URL] {
        clipboard.readURLs().filter { $0.isFileURL || RemoteFS.isRemote($0) }
    }

    var clipboardIsCut: Bool { clipboard.changeCount == cutChangeCount }

    /// "Paste", "Paste 3 Files", "Paste One Folder" — Dolphin's dynamic label.
    public var pasteTitle: String {
        let urls = clipboardURLs
        if urls.isEmpty { return "Paste" }
        let dirs = urls.filter {
            $0.isFileURL ? (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true : $0.hasDirectoryPath
        }.count
        if urls.count == 1 { return dirs == 1 ? "Paste One Folder" : "Paste One File" }
        if dirs == urls.count { return "Paste \(urls.count) Folders" }
        if dirs == 0 { return "Paste \(urls.count) Files" }
        return "Paste \(urls.count) Items"
    }

    public func paste(into folder: URL, window: AnyObject?, done: (([URL]) -> Void)? = nil) {
        let urls = clipboardURLs
        guard !urls.isEmpty else { return }
        let cut = clipboardIsCut
        run(cut ? .move : .copy, urls, to: folder, window: window) { [weak self] results in
            if cut, let self {
                self.cutChangeCount = -1
                self.cutURLs = []
                self.clipboard.clear()
                NotificationCenter.default.post(name: Self.cutChanged, object: nil)
            }
            done?(results)
        }
    }

    // MARK: Jobs

    /// `sound` plays once the job has done something (Finder's trash sounds).
    public func run(_ kind: FileOperationKind, _ urls: [URL], to folder: URL? = nil, window: AnyObject?, sound: FinderSound? = nil,
                    done: (([URL]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        if urls.contains(where: { !$0.isFileURL }) || (folder.map { !$0.isFileURL } ?? false) {
            runRemote(kind, urls, to: folder, window: window, done: done)
            return
        }
        let job = FileJob(kind: kind, sources: urls, destinationFolder: folder)
        ui?.jobStarted(job)
        job.onProgress = { [weak self, weak job] p in
            DispatchQueue.main.async { if let job { self?.ui?.jobProgressed(job, p) } }
        }
        job.resolveConflict = { [weak self] info in
            var answer = ConflictAnswer(.cancel)
            DispatchQueue.main.sync { answer = self?.ui?.resolveConflict(info, kind: kind) ?? ConflictAnswer(.cancel) }
            return answer
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var record: UndoRecord?
            var fatal: Error?
            do { record = try job.run() } catch { fatal = error }
            DispatchQueue.main.async {
                Self.notifyChanged(urls + (folder.map { [$0] } ?? []) + job.results)
                self.ui?.jobFinished(job)
                if let r = record { self.pushUndo(r); self.recordTrash(r) }
                // One sound per action: now, or once the items needing authentication are done too.
                let deniedLeft = !job.denied.isEmpty && !job.isCancelled
                if record != nil && !deniedLeft { sound?.play() }
                let errs = job.errors + (fatal.map { [($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription] } ?? [])
                if !errs.isEmpty && !job.isCancelled { self.showErrors(errs, window: window) }
                if !job.untrashable.isEmpty && !job.isCancelled { self.offerDelete(job.untrashable, window: window) }
                if !job.denied.isEmpty && !job.isCancelled {
                    self.retryDenied(kind, job.denied, targets: job.deniedTargets, to: folder, window: window) { more in
                        if record != nil || !more.isEmpty { sound?.play() }
                        done?(job.results + more)
                    }
                } else {
                    done?(job.results)
                }
            }
        }
    }

    /// Moves items to the Trash; `sound` is Finder's: "move to trash", or "drag to trash" for the Dock's Trash.
    public func trash(_ urls: [URL], window: AnyObject?, sound: FinderSound = .moveToTrash) {
        guard !urls.isEmpty else { return }
        let remote = urls.filter { !$0.isFileURL }
        if !remote.isEmpty {
            // Remote locations have no Trash (Dolphin deletes permanently there, after asking). Local items
            // in the same selection still go to the Trash.
            let q = Confirmation(
                message: remote.count == 1 ? "Permanently delete “\(remote[0].lastPathComponent)”?" : "Permanently delete these \(remote.count) items?",
                detail: "Remote locations don't have a Trash. This action cannot be undone.",
                confirmTitle: "Delete", warning: true, destructive: true)
            guard confirm(q, window: window) else { return }
            runRemote(.delete, remote, to: nil, window: window, done: nil)
        }
        // Apple's own apps live on the read-only system volume: macOS doesn't allow removing them.
        let builtIn = urls.filter { $0.isFileURL && AppLibrary.isBuiltIn($0) }
        if !builtIn.isEmpty {
            _ = confirm(Confirmation(
                message: builtIn.count == 1
                    ? "“\(AppLibrary.displayName(builtIn[0]))” is part of macOS and can't be moved to the Trash."
                    : "\(builtIn.count) of these items are part of macOS and can't be moved to the Trash.",
                detail: "macOS keeps its built-in apps on a protected system volume."), window: window)
        }
        let local = urls.filter { $0.isFileURL && !AppLibrary.isBuiltIn($0) }
        guard !local.isEmpty else { return }
        if Settings.shared.confirmTrash {
            let q = Confirmation(
                message: local.count == 1 ? "Do you really want to move “\(local[0].lastPathComponent)” to the Trash?"
                    : "Do you really want to move these \(local.count) items to the Trash?",
                confirmTitle: "Move to Trash", suppressible: true)
            guard confirm(q, window: window, dontAskAgain: { Settings.shared.confirmTrash = false }) else { return }
        }
        run(.trash, local, window: window, sound: sound)
    }

    /// Finder: items on a volume without a Trash can only be deleted right away, after asking.
    private func offerDelete(_ urls: [URL], window: AnyObject?) {
        let q = Confirmation(
            message: urls.count == 1
                ? "“\(urls[0].lastPathComponent)” can't be moved to the Trash. Do you want to delete it immediately?"
                : "These \(urls.count) items can't be moved to the Trash. Do you want to delete them immediately?",
            detail: "Their volume has no Trash. This action cannot be undone.",
            confirmTitle: "Delete", warning: true, destructive: true)
        guard confirm(q, window: window) else { return }
        run(.delete, urls, window: window)
    }

    public func delete(_ urls: [URL], window: AnyObject?) {
        guard !urls.isEmpty else { return }
        if Settings.shared.confirmDelete {
            let q = Confirmation(
                message: urls.count == 1 ? "Do you really want to delete “\(urls[0].lastPathComponent)”?"
                    : "Do you really want to delete these \(urls.count) items?",
                detail: "This action cannot be undone.",
                confirmTitle: "Delete", warning: true, destructive: true, suppressible: true)
            guard confirm(q, window: window, dontAskAgain: { Settings.shared.confirmDelete = false }) else { return }
        }
        run(.delete, urls, window: window)
    }

    /// Empties the Trash of the home folder and of every mounted volume, as Finder does.
    public func emptyTrash(window: AnyObject?) {
        let fm = FileManager.default
        let items = Self.allTrashFolders().flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        if items.isEmpty { return }
        if Settings.shared.confirmEmptyTrash {
            let q = Confirmation(
                message: "Do you really want to empty the Trash? All items will be deleted.",
                detail: "This action cannot be undone.",
                confirmTitle: "Empty Trash", warning: true, destructive: true, suppressible: true)
            guard confirm(q, window: window, dontAskAgain: { Settings.shared.confirmEmptyTrash = false }) else { return }
        }
        FinderSound.emptyTrash.play()   // Finder plays it as emptying starts
        run(.delete, items, window: window)
    }

    /// ~/.Trash plus the per-user Trash folders of other mounted volumes (/Volumes/X/.Trashes/<uid>).
    private static func allTrashFolders() -> [URL] {
        let fm = FileManager.default
        var folders = [TrashInfo.folder]
        for v in fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] where v.path != "/" {
            let t = v.appendingPathComponent(".Trashes/\(getuid())")
            if FileJob.itemExists(at: t), !folders.contains(t) { folders.append(t) }
        }
        return folders
    }

    // MARK: Talking to the user

    /// Asks through `ui`; `dontAskAgain` runs when the user confirmed with "Do not ask again" ticked.
    func confirm(_ q: Confirmation, window: AnyObject?, dontAskAgain: (() -> Void)? = nil) -> Bool {
        guard let answer = ui?.confirm(q, window: window), answer.confirmed else { return false }
        if answer.dontAskAgain { dontAskAgain?() }
        return true
    }

    func showErrors(_ errs: [String], window: AnyObject?) { ui?.showErrors(errs, window: window) }
}
