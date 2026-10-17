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
        let dirs = Set(
            urls.flatMap { url in
                url.isFileURL
                    ? [FilePath.entry(url.path), FilePath.canonical(url.deletingLastPathComponent().path)]
                    : [url.path, url.deletingLastPathComponent().path]
            })
        NotificationCenter.default.post(name: foldersChanged, object: nil, userInfo: ["paths": dirs])
    }

    /// Dialogs and progress (set by the app; without it nothing is confirmed and conflicts cancel).
    public var ui: FileOperationsUI?
    public var clipboard: FileClipboard = LocalClipboard()
    /// Undoes cloud changes (tests pair a controller with their own accounts model).
    public weak var cloud: CloudAccounts?

    var undoStack: [UndoRecord] = []
    var redoStack: [UndoRecord] = []
    private var cutChangeCount = -1
    public private(set) var cutURLs: Set<URL> = []
    /// Every job of this session, queued, running or ended (the Activity window), oldest first.
    public internal(set) var activities: [Activity] = []
    /// Where unfinished jobs are written down, to be resumed after a relaunch.
    public var journals = JournalStore(folder: JournalStore.defaultFolder)
    public var driveJournals = DriveMutationJournal.shared
    public var history = OperationHistory.shared
    /// Cancelling a remote transfer (by activity).
    var remoteCancel: [UUID: () -> Void] = [:]
    /// Once shutdown starts, finishing a worker must not start another queued operation.
    var isInterrupting = false
    /// Tests: adjusts each local job before it's queued (no clones, slower chunks…).
    var prepareJob: ((FileJob) -> Void)?

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
    public func run(
        _ kind: FileOperationKind, _ urls: [URL], to folder: URL? = nil, window: AnyObject?, sound: FinderSound? = nil,
        allowDeleteFallback: Bool = true, resumePoints: [URL: ResumePoint] = [:], completedTransfers: [URL: URL] = [:], done: (([URL]) -> Void)? = nil
    ) {
        guard !urls.isEmpty else { return }
        if urls.contains(where: { !$0.isFileURL }) || (folder.map { !$0.isFileURL } ?? false) {
            runRemote(kind, urls, to: folder, window: window, done: done)
            return
        }
        let job = FileJob(kind: kind, sources: urls, destinationFolder: folder)
        job.resumePoints = resumePoints
        job.completedTransfers = completedTransfers
        job.conflictRule = Settings.shared.transferConflictRule
        job.comparisonOptions = TransferCompareOptions(method: Settings.shared.transferCompareMethod)
        job.disposeReplacedItem = replacementDisposal
        job.trashItem = { try TrashService.shared.trash([$0]).first?.inTrash }
        prepareJob?(job)
        let activity = Activity(kind: kind, sources: urls, destination: folder, job: job)
        activity.originWindow = window
        activity.start = { [weak self, weak activity] in
            guard let self, let activity, activity.state == .queued else { return }
            self.start(activity, job: job, window: window, sound: sound, allowDeleteFallback: allowDeleteFallback, done: done)
        }
        enqueue(activity)
    }

    /// Runs a queued job.
    private func start(
        _ activity: Activity, job: FileJob, window: AnyObject?, sound: FinderSound?, allowDeleteFallback: Bool, done: (([URL]) -> Void)?
    ) {
        let kind = activity.kind, urls = activity.sources, folder = activity.destination
        began(activity)
        ui?.jobStarted(activity)
        job.onNoSpace = { [weak self, weak activity, weak job] bytes in
            guard let job else { return false }
            return self?.awaitDiskSpace(bytes, activity: activity, job: job.control, window: window) ?? false
        }
        job.onProgress = { [weak self, weak activity] p in
            DispatchQueue.main.async {
                if let activity { self?.ui?.jobProgressed(activity, p) }
                if let activity { self?.progressed(activity, p) }
            }
        }
        job.resolveConflict = { [weak self, weak activity, weak job] info in
            guard let job else { return .init(.cancel) }
            return self?.awaitConflict(info, kind: kind, activity: activity, job: job.control, window: window) ?? .init(.cancel)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var record: UndoRecord?
            var fatal: Error?
            do { record = try job.run() } catch { fatal = error }
            DispatchQueue.main.async {
                Self.notifyChanged(urls + (folder.map { [$0] } ?? []) + job.results)
                self.ui?.jobFinished(activity)
                if let r = record { self.pushUndo(r) }
                let errs = job.errors + (fatal.map { [($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription] } ?? [])
                self.ended(activity, errors: errs)
                // Quitting: nothing more to say or do now; the journal resumes it next time.
                if job.isInterrupted { return }
                // One sound per action: now, or once the items needing authentication are done too.
                let deniedLeft = !job.denied.isEmpty && !job.isCancelled
                if record != nil && !deniedLeft { sound?.play() }
                if !errs.isEmpty && !job.isCancelled { self.ui?.showTransferErrors(activity, window: window) }
                if !job.untrashable.isEmpty && !job.isCancelled {
                    if allowDeleteFallback {
                        self.offerDelete(job.untrashable, window: window)
                    } else {
                        self.showErrors(
                            ["These items could not be moved to Trash: " + job.untrashable.map(\.path).joined(separator: ", ")], window: window)
                    }
                }
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
        let cloud = urls.filter(PlacesModel.isCloud)
        if !cloud.isEmpty { ui?.trashCloud(cloud, window: window) }
        let remote = urls.filter { !$0.isFileURL && !PlacesModel.isCloud($0) }
        if !remote.isEmpty {
            // Remote locations have no Trash (Dolphin deletes permanently there, after asking). Local items
            // in the same selection still go to the Trash.
            let q = Confirmation(
                message: remote.count == 1
                    ? "Permanently delete “\(remote[0].lastPathComponent)”?" : "Permanently delete these \(remote.count) items?",
                detail: "Remote locations don't have a Trash. This action cannot be undone.",
                confirmTitle: "Delete", warning: true, destructive: true)
            if confirm(q, window: window) { runRemote(.delete, remote, to: nil, window: window, done: nil) }
        }
        // Apple's own apps live on the read-only system volume: macOS doesn't allow removing them.
        let builtIn = urls.filter { $0.isFileURL && AppLibrary.isBuiltIn($0) }
        if !builtIn.isEmpty {
            _ = confirm(
                Confirmation(
                    message: builtIn.count == 1
                        ? "“\(AppLibrary.displayName(builtIn[0]))” is part of macOS and can't be moved to the Trash."
                        : "\(builtIn.count) of these items are part of macOS and can't be moved to the Trash.",
                    detail: "macOS keeps its built-in apps on a protected system volume."), window: window)
        }
        let local = urls.filter { $0.isFileURL && !AppLibrary.isBuiltIn($0) }
        guard !local.isEmpty else { return }
        let applications = local.filter { $0.pathExtension.lowercased() == "app" }
        if !applications.isEmpty, let ui, ui.reviewsAppCleanup {
            ui.reviewAppCleanup(local, window: window) { related in
                guard let related else { return }
                self.trashLocal(Array(Set(local + related)), window: window, sound: sound, allowDeleteFallback: false, confirmed: true)
            }
            return
        }
        trashLocal(local, window: window, sound: sound, allowDeleteFallback: true)
    }

    private func trashLocal(_ local: [URL], window: AnyObject?, sound: FinderSound, allowDeleteFallback: Bool, confirmed: Bool = false) {
        if !confirmed && Settings.shared.confirmTrash {
            let q = Confirmation(
                message: local.count == 1
                    ? "Do you really want to move “\(local[0].lastPathComponent)” to the Trash?"
                    : "Do you really want to move these \(local.count) items to the Trash?",
                confirmTitle: "Move to Trash", suppressible: true)
            guard confirm(q, window: window, dontAskAgain: { Settings.shared.confirmTrash = false }) else { return }
        }
        run(.trash, local, window: window, sound: sound, allowDeleteFallback: allowDeleteFallback)
    }

    /// Finder: items on a volume without a Trash can only be deleted right away, after asking.
    func offerDelete(_ urls: [URL], window: AnyObject?) {
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
        // Cloud items are never deleted from here: they go to the service's Trash, where they can be restored.
        let cloud = urls.filter(PlacesModel.isCloud)
        if !cloud.isEmpty { ui?.trashCloud(cloud, window: window) }
        let urls = urls.filter { !PlacesModel.isCloud($0) }
        guard !urls.isEmpty else { return }
        if Settings.shared.confirmDelete {
            let q = Confirmation(
                message: urls.count == 1
                    ? "Do you really want to delete “\(urls[0].lastPathComponent)”?"
                    : "Do you really want to delete these \(urls.count) items?",
                detail: "This action cannot be undone.",
                confirmTitle: "Delete", warning: true, destructive: true, suppressible: true)
            guard confirm(q, window: window, dontAskAgain: { Settings.shared.confirmDelete = false }) else { return }
        }
        run(.delete, urls, window: window)
    }

    /// Empties the Trash of the home folder and of every mounted volume, as Finder does.
    public func emptyTrash(window: AnyObject?) { emptyTrash(Self.allTrashFolders(), window: window) }

    /// Empties these Trash folders (tests pass their own, never the user's Trash).
    func emptyTrash(_ folders: [URL], window: AnyObject?) {
        let fm = FileManager.default
        let items = folders.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        if items.isEmpty { return }
        if Settings.shared.confirmEmptyTrash {
            let q = Confirmation(
                message: "Do you really want to empty the Trash? All items will be deleted.",
                detail: "This action cannot be undone.",
                confirmTitle: "Empty Trash", warning: true, destructive: true, suppressible: true)
            guard confirm(q, window: window, dontAskAgain: { Settings.shared.confirmEmptyTrash = false }) else { return }
        }
        FinderSound.emptyTrash.play()  // Finder plays it as emptying starts
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

extension FileOperationsController {
    func awaitDiskSpace(_ bytes: Int64, activity: Activity?, job: JobControl, window: AnyObject?) -> Bool {
        let reply = ConflictReply()
        job.pause()
        DispatchQueue.main.async { [weak self, weak activity] in
            guard let self, let ui = self.ui, !job.isCancelled, !job.isInterrupted else { reply.finish(.init(.cancel)); return }
            activity?.state = .paused
            self.activityDidChange()
            ui.resolveDiskFull(destination: activity?.destination, source: activity?.sources.first, neededBytes: bytes, window: window, job: job) {
                retry in
                job.resume()
                if !retry { job.cancel() }
                activity?.rate.reset()
                activity?.state = .running
                self.activityDidChange()
                reply.finish(.init(retry ? .overwrite : .cancel))
            }
        }
        while true {
            if let answer = reply.wait() { return answer.resolution == .overwrite }
            if job.isCancelled || job.isInterrupted {
                DispatchQueue.main.async { [weak self] in self?.ui?.cancelConflict(for: job) }
                return false
            }
        }
    }

    /// Only the worker waits. Sheets and unrelated jobs keep servicing the main run loop.
    func awaitConflict(_ info: ConflictInfo, kind: FileOperationKind, activity: Activity?, job: JobControl, window: AnyObject?) -> ConflictAnswer {
        let reply = ConflictReply()
        DispatchQueue.main.async { [weak self, weak activity] in
            guard let self, let ui = self.ui, !job.isCancelled, !job.isInterrupted else { reply.finish(.init(.cancel)); return }
            activity?.state = .waiting
            self.activityDidChange()
            ui.resolveConflict(info, kind: kind, window: window, job: job) { [weak self, weak activity] answer in
                activity?.rate.reset()
                if activity?.state == .waiting { activity?.state = job.isPaused ? .paused : .running }
                self?.activityDidChange()
                reply.finish(answer)
            }
        }
        while true {
            if let answer = reply.wait() { return answer }
            if job.isCancelled || job.isInterrupted {
                DispatchQueue.main.async { [weak self] in self?.ui?.cancelConflict(for: job) }
                return .init(.cancel)
            }
        }
    }
}

private final class ConflictReply: @unchecked Sendable {
    private let condition = NSCondition()
    private var answer: ConflictAnswer?
    func finish(_ answer: ConflictAnswer) {
        condition.lock(); defer { condition.unlock() }
        guard self.answer == nil else { return }
        self.answer = answer
        condition.signal()
    }
    func wait() -> ConflictAnswer? {
        condition.lock(); defer { condition.unlock() }
        if answer == nil { _ = condition.wait(until: Date().addingTimeInterval(0.1)) }
        return answer
    }
}
