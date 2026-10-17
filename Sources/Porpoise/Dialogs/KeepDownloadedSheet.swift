import AppKit
import PorpoiseCore
import PorpoiseServices

/// Download on cloud items: iCloud Drive items download now; account items stay on this Mac until Remove Download,
/// counted first: it asks before a big folder, and says plainly when it won't fit on this Mac.
enum KeepDownloadedSheet {
    /// Download for any selection (menus, the cloud badge).
    static func download(
        _ items: [FileItem], window: NSWindow?, status: @escaping (String?) -> Void = { _ in }, failed: ((String) -> Void)? = nil
    ) {
        let remote = Set(CloudCommands.downloadNow(items.map(\.url)))
        guard !remote.isEmpty else { return }
        // Unless the caller shows it otherwise, a failure is said on the window the download was asked from.
        let failed = failed ?? { [weak window] in Prompt.message($0, on: window) }
        run(items.filter { remote.contains($0.url) }, window: window, status: status, failed: failed)
    }

    /// The question for a plan; nil when it can start straight away.
    static func alert(for plan: CloudKeepPlan, name: String, folder: Bool) -> NSAlert? {
        guard !plan.fits || plan.needsConfirmation else { return nil }
        let a = NSAlert()
        a.informativeText = CloudCommands.planText(plan, folder: folder)
        if plan.fits {
            a.messageText = "Download “\(name)”?"
            a.addButton(withTitle: "Download")
            a.addButton(withTitle: "Cancel")
        } else {
            a.messageText = "“\(name)” won’t fit on this Mac."
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Manage Storage…")
        }
        return a
    }

    /// Plans downloading `items`, confirms if needed, then keeps them on this Mac. `status` shows "Counting “Photos”…".
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
                failed("Couldn’t download “\(name)”: \(error.localizedDescription)")
            case .success(let plan):
                guard let a = alert(for: plan, name: name, folder: folder) else { return service.keep(urls) }
                let answer: (NSApplication.ModalResponse) -> Void = { r in
                    if plan.fits, r == .alertFirstButtonReturn { service.keep(urls) }
                    if !plan.fits, r == .alertSecondButtonReturn { (NSApp.delegate as? AppDelegate)?.showSettings(page: "Accounts") }
                }
                a.runSheet(for: window, answer)
            }
        }
    }
}
