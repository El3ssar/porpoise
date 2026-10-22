import AppKit
import PorpoiseServices

/// Help › Report a Bug: shows exactly what a report would carry, then opens GitHub's bug form with the versions
/// filled in, or saves the diagnostics to attach. Nothing leaves the Mac until the person submits the form.
enum BugReportDialog {
    /// The app's diagnostic trace: process memory only, never written or sent on its own (docs/DIAGNOSTICS.md).
    static let diagnostics = DiagnosticStore()

    static func run(window: NSWindow?) {
        let draft: BugReportDraft
        do { draft = try BugReportDraft(store: diagnostics) } catch {
            NSWorkspace.shared.open(URL(string: AppInfo.newIssue)!)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Report a Bug"
        alert.informativeText =
            "Porpoise opens a new bug report on GitHub with \(draft.summary) filled in. Nothing is sent until you "
            + "submit it there.\n\nThe diagnostics below hold no file names, paths, servers or accounts. Save them "
            + "to attach them to your report."
        alert.accessoryView = preview(draft.diagnostics.text)
        alert.addButton(withTitle: "Open Bug Report")
        alert.addButton(withTitle: "Save Diagnostics…")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(draft.issueURL(repository: AppInfo.repository))
            case .alertSecondButtonReturn: save(draft.diagnostics, window: window)
            default: break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// The exact bytes that are saved, read-only and selectable.
    static func preview(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 420, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = text
        view.autoresizingMask = [.width]
        view.setAccessibilityLabel("Diagnostics")
        scroll.documentView = view
        return scroll
    }

    private static func save(_ export: DiagnosticExport, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BugReportDraft.fileName()
        panel.allowedContentTypes = [.json]
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try export.write(to: url) } catch {
                let failed = NSAlert()
                failed.messageText = "Couldn’t save the diagnostics"
                failed.informativeText = "Choose a new name or another folder, then try again."
                failed.runModal()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }
}

extension AppDelegate {
    @objc func reportBug(_ sender: Any?) { BugReportDialog.run(window: NSApp.keyWindow) }

    /// The website's step-by-step install and first-launch guide.
    @objc func showInstallGuide(_ sender: Any?) {
        if let u = URL(string: AppInfo.installGuide) { NSWorkspace.shared.open(u) }
    }
}
