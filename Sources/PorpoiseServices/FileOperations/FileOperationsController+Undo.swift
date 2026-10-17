import Foundation
import PorpoiseCore

// MARK: Undo

extension FileOperationsController {
    public func pushUndo(_ r: UndoRecord) {
        undoStack.append(r)
        redoStack.removeAll()
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
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo(window: AnyObject?) {
        guard let r = undoStack.popLast() else { return }
        if case .cloud(let change) = r {
            revertCloud(change, window: window, back: { self.undoStack.append($0) }, inverse: { self.redoStack.append($0) })
            return
        }
        if case .remote(let change) = r {
            revertRemote(change, window: window, back: { self.undoStack.append($0) }, inverse: { self.redoStack.append($0) })
            return
        }
        switch revert(r) {
        case .success(let inverse): if let inverse { redoStack.append(inverse) }; stacksChanged()
        case .failure(let error): undoStack.append(r); stacksChanged(); showErrors([error.localizedDescription], window: window)
        }
    }

    public func redo(window: AnyObject?) {
        guard let r = redoStack.popLast() else { return }
        if case .cloud(let change) = r {
            revertCloud(change, window: window, back: { self.redoStack.append($0) }, inverse: { self.undoStack.append($0) })
            return
        }
        if case .remote(let change) = r {
            revertRemote(change, window: window, back: { self.redoStack.append($0) }, inverse: { self.undoStack.append($0) })
            return
        }
        switch revert(r) {
        case .success(let inverse): if let inverse { undoStack.append(inverse) }; stacksChanged()
        case .failure(let error): redoStack.append(r); stacksChanged(); showErrors([error.localizedDescription], window: window)
        }
    }

    /// FileActions.undo is all-or-nothing, so a record that failed is still valid and goes back on its
    /// stack for another try (e.g. after the user frees the original name). The stacks are changed by the
    /// callers before any alert: a job finishing during the alert pushes onto them.
    private func revert(_ r: UndoRecord) -> Result<UndoRecord?, Error> {
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
        stacksChanged()
        (cloud ?? CloudAccounts.shared).revert(change) { [weak self] error in
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
        stacksChanged()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try LocationOperations.revert(change) }
            DispatchQueue.main.async { [weak self] in
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
