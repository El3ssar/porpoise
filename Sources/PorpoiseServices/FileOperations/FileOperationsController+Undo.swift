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
        }
    }

    public var undoTitle: String? { undoStack.last.map { "Undo: \($0.label)" } }
    public var redoTitle: String? { redoStack.last.map { "Redo: \($0.label)" } }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo(window: AnyObject?) {
        guard let r = undoStack.popLast() else { return }
        switch revert(r) {
        case .success(let inverse): if let inverse { redoStack.append(inverse) }; stacksChanged()
        case .failure(let error): undoStack.append(r); stacksChanged(); showErrors([error.localizedDescription], window: window)
        }
    }

    public func redo(window: AnyObject?) {
        guard let r = redoStack.popLast() else { return }
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
            let inverse = try FileActions.undo(r)
            if let inverse { Self.notifyChanged(Self.urls(of: inverse)) }
            return .success(inverse)
        } catch {
            return .failure(error)
        }
    }

    private func stacksChanged() { NotificationCenter.default.post(name: Self.undoChanged, object: nil) }
}
