import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem
@testable import PorpoiseServices

@MainActor @Suite(.serialized, .isolatedSettings) struct PartialUndoHistoryTests {
    @Test(arguments: [false, true], [false, true])
    func partialResultsReconcileBothStacks(redo: Bool, offMain: Bool) async throws {
        let s = try Scratch("partial-history")
        let a = s.path("original/a"), b = try s.file("original/b", "occupied")
        let movedA = try s.file("moved/a", "a"), movedB = try s.file("moved/b", "b")
        let record = UndoRecord.moved([(from: b, to: movedB), (from: a, to: movedA)])
        let ui = ScriptedUI(), controller = makeController(ui)
        controller.localUndo = { record, trash in
            try FileActions.undo(record, trash: trash) { from, to in
                try FileManager.default.moveItem(at: from, to: to)
                if from == movedA { try Data("arrival".utf8).write(to: movedA, options: .withoutOverwriting) }
            }
        }
        let originalCopiesData = FileOperationsController.copiesData
        FileOperationsController.copiesData = { _ in offMain }
        defer { FileOperationsController.copiesData = originalCopiesData }
        if redo { controller.redoStack = [record] } else { controller.pushUndo(record) }
        if redo { controller.redo(window: nil) } else { controller.undo(window: nil) }
        if offMain { await ui.nextJobFinished() }
        #expect(controller.canUndo && controller.canRedo)
        #expect(controller.undoStack.count == 1 && controller.redoStack.count == 1)
        let remaining = try #require((redo ? controller.redoStack : controller.undoStack).last)
        let inverse = try #require((redo ? controller.undoStack : controller.redoStack).last)
        guard case .moved(let rest) = remaining, case .moved(let completed) = inverse else {
            Issue.record("Expected two reconciled move records"); return
        }
        #expect(rest.count == 1 && rest[0].from == b && rest[0].to == movedB)
        #expect(completed.count == 1 && completed[0].from == movedA && completed[0].to == a)
        #expect(s.read("original/a") == "a" && s.read("moved/a") == "arrival")
        #expect(s.read("original/b") == "occupied" && s.read("moved/b") == "b")
        #expect(ui.errors.count == 1 && ui.errors[0].contains(a.path))
        if offMain { #expect(controller.activities.last?.state == .failed) }
        controller.localUndo = { try FileActions.undo($0, trash: $1) }
        try FileManager.default.removeItem(at: b)
        if redo { controller.redo(window: nil) } else { controller.undo(window: nil) }
        if offMain { await ui.nextJobFinished() }
        #expect(s.read("original/b") == "b" && !FileJob.itemExists(at: movedB))
    }

    @Test func anActionRecordedDuringPartialUndoStillDropsStaleRedo() throws {
        let s = try Scratch("partial-history-generation")
        let a = s.path("original/a"), b = try s.file("original/b", "occupied")
        let movedA = try s.file("moved/a", "a"), movedB = try s.file("moved/b", "b")
        let newer = try s.file("newer", "new")
        let controller = makeController(ScriptedUI())
        controller.localUndo = { [weak controller] record, trash in
            try FileActions.undo(record, trash: trash) { from, to in
                try FileManager.default.moveItem(at: from, to: to)
                if from == movedA {
                    try Data("arrival".utf8).write(to: movedA, options: .withoutOverwriting)
                    controller?.pushUndo(.created([newer]))
                }
            }
        }
        controller.pushUndo(.moved([(from: b, to: movedB), (from: a, to: movedA)]))
        controller.undo(window: nil)
        #expect(controller.undoStack.count == 2 && !controller.canRedo)
        guard case .created(let urls)? = controller.undoStack.last, case .moved(let rest)? = controller.undoStack.first else {
            Issue.record("Expected partial remainder below the newer action"); return
        }
        #expect(urls == [newer] && rest.count == 1 && rest[0].from == b)
    }
}
