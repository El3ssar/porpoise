import Foundation
import PorpoiseCore
import PorpoiseFileSystem

// MARK: Undo

extension FileOperationsController {
    public func pushUndo(_ r: UndoRecord) {
        undoStack.append(r)
        redoStack.removeAll()
        actionsRecorded += 1
        NotificationCenter.default.post(name: Self.undoChanged, object: nil)
    }

    public static func urls(of r: UndoRecord) -> [URL] {
        switch r {
        case .created(let u): return u
        case .moved(let p): return p.flatMap { [$0.from, $0.to] }
        case .trashed(let p): return p.flatMap { [$0.original, $0.inTrash] }
        case .renamed(let a, let b): return [a, b]
        case .batchRenamed(let steps): return steps.flatMap { [$0.from, $0.to] }
        case .cloud(let change): return change.urls
        case .remote(let change): return change.urls
        }
    }

    public var undoTitle: String? { undoStack.last.map { "Undo: \($0.label)" } }
    public var redoTitle: String? { redoStack.last.map { "Redo: \($0.label)" } }
    public var canUndo: Bool { !undoStack.isEmpty && undosRunning == 0 }
    public var canRedo: Bool { !redoStack.isEmpty && undosRunning == 0 }

    /// One at a time. An action recorded while it runs stays on top: the record goes back below it if the undo
    /// fails, and its inverse isn't offered as Redo (the action cleared Redo).
    public func undo(window: AnyObject?) {
        guard undosRunning == 0, let r = undoStack.popLast() else { return }
        let slot = undoStack.count, recorded = actionsRecorded
        let back = { self.undoStack.insert($0, at: min(slot, self.undoStack.count)) }
        let inverse = { if self.actionsRecorded == recorded { self.redoStack.append($0) } }
        if case .cloud(let change) = r {
            revertCloud(change, window: window, back: back, inverse: inverse)
            return
        }
        if case .remote(let change) = r {
            revertRemote(change, window: window, back: back, inverse: inverse)
            return
        }
        revertLocal(r, window: window, back: back, inverse: inverse)
    }

    /// As `undo`: an action recorded meanwhile drops a failed redo, and the redone record goes below that action.
    public func redo(window: AnyObject?) {
        guard undosRunning == 0, let r = redoStack.popLast() else { return }
        let slot = undoStack.count, recorded = actionsRecorded
        let back = { if self.actionsRecorded == recorded { self.redoStack.append($0) } }
        let inverse = { self.undoStack.insert($0, at: min(slot, self.undoStack.count)) }
        if case .cloud(let change) = r {
            revertCloud(change, window: window, back: back, inverse: inverse)
            return
        }
        if case .remote(let change) = r {
            revertRemote(change, window: window, back: back, inverse: inverse)
            return
        }
        revertLocal(r, window: window, back: back, inverse: inverse)
    }

    /// Undoes or redoes a record on this Mac. Renames and moves within a volume are instant and happen at once; a
    /// move between volumes copies the data back, so it runs off the main thread as an Activity (the window stays
    /// usable, and Activity shows it), its record off the stacks meanwhile.
    private func revertLocal(
        _ r: UndoRecord, window: AnyObject?, back: @escaping (UndoRecord) -> Void, inverse: @escaping (UndoRecord) -> Void
    ) {
        guard Self.copiesData(r) else {
            switch revert(r) {
            case .success(let i): if let i { inverse(i) }; stacksChanged()
            case .failure(let error): back(r); stacksChanged(); showErrors([error.localizedDescription], window: window)
            }
            return
        }
        stacksChanged()
        let activity = Activity(
            kind: .move, sources: Self.moves(of: r).map(\.from), destination: Self.moves(of: r).first?.to.deletingLastPathComponent(), job: nil,
            pauseUnavailable: "Undo can't be paused.")
        activity.cloudTitle = "Undoing: \(r.label)"
        activity.originWindow = window
        activities.append(activity)
        began(activity)
        ui?.jobStarted(activity)
        activityDidChange()
        undosRunning += 1
        // Items it puts in the Trash (undoing a creation queued behind) can go back where they were.
        TrashService.shared.record([])
        let trash = TrashService.shared.trash
        undoQueue.async {
            let result = Result { try FileActions.undo(r, trash: trash) }
            DispatchQueue.main.async { [self] in
                undosRunning -= 1
                TrashService.shared.flush()
                switch result {
                case .success(let i):
                    if let i {
                        inverse(i)
                        Self.notifyChanged(Self.urls(of: i))
                    }
                    ended(activity, errors: [])
                case .failure(let error):
                    back(r)
                    ended(activity, errors: [error.localizedDescription], cause: error)
                    showErrors([error.localizedDescription], window: window)
                }
                ui?.jobFinished(activity)
                stacksChanged()
            }
        }
    }

    /// The moves undoing `r` makes (where each item is now, and where it goes back to).
    static func moves(of r: UndoRecord) -> [(from: URL, to: URL)] {
        switch r {
        case .moved(let pairs): return pairs.map { (from: $0.to, to: $0.from) }
        case .trashed(let pairs): return pairs.map { (from: $0.inTrash, to: $0.original) }
        case .batchRenamed(let steps): return steps.map { (from: $0.to, to: $0.from) }
        default: return []
        }
    }

    /// Whether undoing `r` moves an item to another volume (a copy of its data, then a delete). Tests set it.
    nonisolated(unsafe) static var copiesData: (UndoRecord) -> Bool = { movesBetweenVolumes($0) }

    /// Decided on the main thread from the mount table alone (`MountTable.mountPoint`): a stat per item there
    /// (a big batch, or a share whose server went away) held the window. A destination folder that's gone (it's
    /// recreated) is covered by the same mount as its path.
    static func movesBetweenVolumes(_ r: UndoRecord) -> Bool {
        moves(of: r).contains { m in
            guard m.from.isFileURL, m.to.isFileURL else { return false }
            let a = MountTable.mountPoint(of: m.from.standardizedFileURL.path)
            let b = MountTable.mountPoint(of: m.to.deletingLastPathComponent().standardizedFileURL.path)
            return a != b
        }
    }

    /// FileActions.undo is all-or-nothing, so a record that failed is still valid and goes back on its
    /// stack for another try (e.g. after the user frees the original name). The stacks are changed by the
    /// callers before any alert: a job finishing during the alert pushes onto them.
    private func revert(_ r: UndoRecord) -> Result<UndoRecord?, Error> {
        defer { TrashService.shared.flush() }
        do {
            TrashService.shared.record([])
            let inverse = try FileActions.undo(r, trash: TrashService.shared.trash)
            if let inverse {
                // Items Undo put in the Trash can go back where they were (Restore to Former Location).
                Self.notifyChanged(Self.urls(of: inverse))
            }
            return .success(inverse)
        } catch {
            return .failure(error)
        }
    }

    /// The service takes a moment: the record is off its stack meanwhile, and goes back there if the service fails.
    private func revertCloud(
        _ change: CloudChange, window: AnyObject?, back: @escaping (UndoRecord) -> Void, inverse: @escaping (UndoRecord) -> Void
    ) {
        undosRunning += 1
        stacksChanged()
        (cloud ?? CloudAccounts.shared).revert(change) { [weak self] error in
            self?.undosRunning -= 1
            if let error {
                back(.cloud(change))
                self?.showErrors([error.localizedDescription], window: window)
            } else {
                inverse(.cloud(change.inverse))
                Self.notifyChanged(change.urls)
                NotificationCenter.default.post(name: CloudAccounts.changeReverted, object: change.urls, userInfo: ["kind": "\(change.kind)"])
            }
            self?.stacksChanged()
        }
    }

    /// A server takes a moment too: the record is off its stack meanwhile, and goes back there if the server refuses.
    private func revertRemote(
        _ change: RemoteChange, window: AnyObject?, back: @escaping (UndoRecord) -> Void, inverse: @escaping (UndoRecord) -> Void
    ) {
        undosRunning += 1
        stacksChanged()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try LocationOperations.revert(change) }
            DispatchQueue.main.async { [weak self] in
                self?.undosRunning -= 1
                switch result {
                case .success:
                    inverse(.remote(change.inverse))
                    Self.notifyChanged(change.urls)
                case .failure(let error):
                    back(.remote(change))
                    self?.showErrors([error.localizedDescription], window: window)
                }
                self?.stacksChanged()
            }
        }
    }

    private func stacksChanged() { NotificationCenter.default.post(name: Self.undoChanged, object: nil) }
}
