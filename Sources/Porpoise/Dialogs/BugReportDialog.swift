import AppKit
import PorpoiseServices

/// Help › Report a Bug: opens GitHub's bug form with the versions filled in, optionally after saving the reviewed
/// diagnostics (Help › Export Diagnostics…'s window) to attach. Nothing leaves the Mac until the person submits the form.
enum BugReportDialog {
    static func run(window: NSWindow?) {
        guard let draft = try? BugReportDraft(store: Diagnostics.shared) else {
            NSWorkspace.shared.open(URL(string: AppInfo.newIssue)!)
            return
        }
        let form = draft.issueURL(repository: AppInfo.repository)
        let alert = NSAlert()
        alert.messageText = "Report a Bug"
        alert.informativeText =
            "Porpoise opens a new bug report on GitHub with \(draft.summary) filled in. Nothing is sent until you "
            + "submit it there.\n\nTo help find the cause, export Porpoise’s diagnostics first and attach the file. "
            + "You see exactly what it holds before saving: no file names, paths, servers or accounts."
        alert.addButton(withTitle: "Open Bug Report")
        alert.addButton(withTitle: "Export Diagnostics…")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(form)
            // Saved: the form opens next, ready for the file to be attached.
            case .alertSecondButtonReturn: DiagnosticsExportWindowController.show { _ in NSWorkspace.shared.open(form) }
            default: break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}

extension AppDelegate {
    @objc func reportBug(_ sender: Any?) { BugReportDialog.run(window: NSApp.keyWindow) }

    /// The website's step-by-step install and first-launch guide.
    @objc func showInstallGuide(_ sender: Any?) {
        if let u = URL(string: AppInfo.installGuide) { NSWorkspace.shared.open(u) }
    }
}
