import AppKit
import PorpoiseCore
import PorpoiseServices

/// The file operations' dialogs and progress panel (`FileOperationsController.ui`).
final class FileOperationsDialogs: FileOperationsUI {
    private let jobsPanel = JobsPanel()

    func confirm(_ q: Confirmation, window: AnyObject?) -> (confirmed: Bool, dontAskAgain: Bool) {
        let a = NSAlert()
        if q.warning { a.alertStyle = .warning }
        a.messageText = q.message
        a.informativeText = q.detail
        if let title = q.confirmTitle {
            a.addButton(withTitle: title)
            a.addButton(withTitle: "Cancel")
            if q.destructive { a.buttons[0].hasDestructiveAction = true }
        }
        if q.suppressible {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Don’t ask again"
        }
        a.window.appearance = NSAppearance(named: .darkAqua)
        let confirmed = a.runModal() == .alertFirstButtonReturn
        return (confirmed, a.suppressionButton?.state == .on)
    }

    func showErrors(_ errs: [String], window: AnyObject?) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = errs.count == 1 ? errs[0] : "\(errs.count) items could not be processed."
        if errs.count > 1 { a.informativeText = errs.prefix(8).joined(separator: "\n") }
        a.window.appearance = NSAppearance(named: .darkAqua)
        // A job can outlive its window; its errors then show on their own instead of on a closed window.
        if let w = window as? NSWindow, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    func resolveConflict(_ info: ConflictInfo, kind: FileOperationKind) -> ConflictAnswer {
        ConflictDialog(info: info, kind: kind).run()
    }

    func jobStarted(_ job: FileJob) { jobsPanel.add(job) }
    func jobProgressed(_ job: FileJob, _ progress: JobProgress) { jobsPanel.update(job, progress) }
    func jobFinished(_ job: FileJob) { jobsPanel.finish(job) }

    func showAuthorizationError(_ msg: String) {
        let e = NSAlert()
        e.alertStyle = .warning
        e.window.appearance = NSAppearance(named: .darkAqua)
        guard msg.contains("Operation not permitted") else { e.messageText = msg; e.runModal(); return }
        // Blocked by macOS's privacy protection: name the switch that's off, and open its list.
        if PrivilegedHelper.isEnabled, PrivilegedHelper.hasFullDiskAccess != true {
            _ = PrivilegedHelper.checkFullDiskAccess(timeout: 3)   // makes sure it's listed
            e.messageText = "Switch on Porpoise Helper under Full Disk Access"
            e.informativeText = "Porpoise Helper does the work on items that belong to the system. macOS lets it into "
                + "your Trash and other private folders once it's switched on (next to Porpoise in the same list). Then try again."
        } else {
            e.messageText = "macOS blocked this"
            e.informativeText = "Check that Porpoise and Porpoise Helper are switched on under Full Disk Access (and Porpoise under App Management for apps), then try again."
        }
        e.addButton(withTitle: "Open Full Disk Access")
        e.addButton(withTitle: "Cancel")
        if e.runModal() == .alertFirstButtonReturn { SystemIntegration.openPrivacyPane("Privacy_AllFiles") }
    }
}

/// The system clipboard, shared with Finder. Test instances use a private one, so automated tests never replace
/// what the user copied.
final class SystemClipboard: FileClipboard {
    private let pasteboard: NSPasteboard = Settings.isTesting
        ? NSPasteboard(name: NSPasteboard.Name("app.porpoise.Porpoise.test-clipboard." + (ProcessInfo.processInfo.environment["PORPOISE_BRIDGE"] ?? "test")))
        : .general

    var changeCount: Int { pasteboard.changeCount }

    /// One file URL per item, as Finder writes them, so Finder (and other apps) can paste; plus the locations as
    /// text for text fields and terminals.
    func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        pasteboard.setString(urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n"), forType: .string)
    }

    func readURLs() -> [URL] { (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? [] }

    func clear() { pasteboard.clearContents() }
}
