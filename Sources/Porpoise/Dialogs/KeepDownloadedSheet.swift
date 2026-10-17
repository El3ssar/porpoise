import AppKit
import PorpoiseCore
import PorpoiseServices

/// Keep Downloaded on cloud items: counts what it takes first, asks before a big folder, and says plainly when it
/// won't fit on this Mac.
enum KeepDownloadedSheet {
    /// The question for a plan; nil when it can start straight away.
    static func alert(for plan: CloudKeepPlan, name: String, folder: Bool) -> NSAlert? {
        guard !plan.fits || plan.needsConfirmation else { return nil }
        let a = NSAlert()
        a.informativeText = CloudCommands.planText(plan, folder: folder)
        if plan.fits {
            a.messageText = "Keep “\(name)” downloaded?"
            a.addButton(withTitle: "Keep Downloaded")
            a.addButton(withTitle: "Cancel")
        } else {
            a.messageText = "“\(name)” won’t fit on this Mac."
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Manage Storage…")
        }
        return a
    }

    /// Plans keeping `items`, confirms if needed, then keeps them. `status` shows "Counting “Photos”…".
    static func run(_ items: [FileItem], window: NSWindow?, status: @escaping (String?) -> Void, failed: @escaping (String) -> Void) {
        guard let service = CloudOfflineHub.service, !items.isEmpty else { return }
        let urls = items.map(\.url)
        let name = items.count == 1 ? items[0].name : "\(items.count) items"
        let folder = items.contains(where: \.isBrowsableFolder)
        if folder { status("Counting “\(name)”…") }
        _ = service.plan(keep: urls) { result in
            status(nil)
            switch result {
            case .failure(let error):
                failed("Couldn’t keep “\(name)” downloaded: \(error.localizedDescription)")
            case .success(let plan):
                guard let a = alert(for: plan, name: name, folder: folder) else { return service.keep(urls) }
                let answer: (NSApplication.ModalResponse) -> Void = { r in
                    if plan.fits, r == .alertFirstButtonReturn { service.keep(urls) }
                    if !plan.fits, r == .alertSecondButtonReturn { (NSApp.delegate as? AppDelegate)?.showSettings(page: "Accounts") }
                }
                if let window { a.beginSheetModal(for: window, completionHandler: answer) } else { answer(a.runModal()) }
            }
        }
    }
}
