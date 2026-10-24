import AppKit
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServices

/// Shared rename confirmation, undo and administrator retry for inline editing and Properties.
@MainActor struct ItemRenaming {
    var confirm: (NSAlert, NSWindow?, @escaping (Bool) -> Void) -> Void = { alert, window, completed in
        alert.runSheet(for: window) { completed($0 == .alertFirstButtonReturn) }
    }
    var operation: @Sendable (URL, String) throws -> (url: URL, undo: UndoRecord?) = { try LocationOperations(for: $0).rename($0, to: $1) }
    var authorize: (URL, URL, NSWindow?) -> Bool = { old, new, window in
        FileOperationsController.shared.authorize(
            verb: "rename", items: [old], commands: FileOperationsController.renameCommands(old, to: new), window: window)
    }

    func rename(_ item: FileItem, to name: String, showingHidden: Bool, window: NSWindow?, completed: @escaping (URL?) -> Void) {
        guard FileActions.isValidName(name) else {
            NSAlert(error: LocationOperationError.invalidName(name)).runSheet(for: window) { _ in completed(nil) }
            return
        }
        var questions: [NSAlert] = []
        func question(_ title: String, _ detail: String, _ action: String) {
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
            alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel"); questions.append(alert)
        }
        let newExtension = (name as NSString).pathExtension
        if Settings.shared.confirmRenameType, !item.isBrowsableFolder, !item.fileExtension.isEmpty,
            newExtension.lowercased() != item.fileExtension.lowercased()
        {
            question(
                "Change File Type",
                "Changing the file extension from “\(item.fileExtension)” to “\(newExtension)” may change the way the file opens.", "Change Type")
        }
        if Settings.shared.confirmRenameHide, name.hasPrefix("."), !item.name.hasPrefix("."), !showingHidden {
            question("Hide this File?", "The name starts with a dot, so the item will be hidden.", "Rename and Hide")
        }
        func perform() {
            let operation = operation
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try operation(item.url, name) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let renamed):
                        if let undo = renamed.undo { FileOperationsController.shared.pushUndo(undo) }
                        FileOperationsController.notifyChanged([item.url, renamed.url]); completed(renamed.url)
                    case .failure(let error):
                        let new = item.url.deletingLastPathComponent().appendingPathComponent(name)
                        if item.url.isFileURL, FileErrorKind.classify(error) == .permission {
                            if authorize(item.url, new, window) {
                                FileOperationsController.shared.pushUndo(.renamed(from: item.url, to: new))
                                FileOperationsController.notifyChanged([item.url, new]); completed(new)
                            } else {
                                completed(nil)
                            }
                        } else {
                            NSAlert(error: error).runSheet(for: window) { _ in completed(nil) }
                        }
                    }
                }
            }
        }
        func ask(_ index: Int) {
            guard questions.indices.contains(index) else { perform(); return }
            confirm(questions[index], window) { accepted in if accepted { ask(index + 1) } else { completed(nil) } }
        }
        ask(0)
    }
}
