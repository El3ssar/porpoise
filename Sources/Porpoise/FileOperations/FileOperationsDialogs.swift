import AppKit
import PorpoiseCore
import PorpoiseServices

/// The file operations' dialogs and progress panel (`FileOperationsController.ui`).
final class FileOperationsDialogs: FileOperationsUI {
    private let jobsPanel = JobsPanel()
    private var diskFullAlerts: [ObjectIdentifier: NSAlert] = [:]
    private var conflicts: [ObjectIdentifier: ConflictDialog] = [:]
    var reviewsAppCleanup: Bool { true }

    func reviewAppCleanup(_ items: [URL], window: AnyObject?, completion: @escaping ([URL]?) -> Void) {
        let applications = items.filter { $0.pathExtension.lowercased() == "app" }
        let env = ProcessInfo.processInfo.environment
        let libraries = Settings.isTesting ? env["PORPOISE_CLEANUP_LIBRARY"].map { [URL(fileURLWithPath: $0)] } : nil
        let roots = Settings.isTesting ? env["PORPOISE_CLEANUP_APPS"].map { [URL(fileURLWithPath: $0)] } : nil
        AppCleanupWindow(
            applications: applications, originals: items, libraries: libraries ?? AppCleanupScanner.libraries,
            catalogRoots: roots ?? (AppLibrary.roots + [URL(fileURLWithPath: "/System/Library/CoreServices")]),
            completion: completion
        ).present()
    }

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
        let confirmed = a.runModal() == .alertFirstButtonReturn
        return (confirmed, a.suppressionButton?.state == .on)
    }

    func trashCloud(_ urls: [URL], window: AnyObject?) {
        let w = (window as? NSWindow)?.windowController as? MainWindowController
        guard let controller = w ?? AppDelegate.shared.windows.first else { return }
        controller.trashCloud(urls)
    }

    func showErrors(_ errs: [String], window: AnyObject?) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = errs.count == 1 ? errs[0] : "\(errs.count) items could not be processed."
        if errs.count > 1 { a.informativeText = errs.prefix(8).joined(separator: "\n") }
        // A job can outlive its window; its errors then show on their own instead of on a closed window.
        if let w = window as? NSWindow, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    func resolveConflict(_ info: ConflictInfo, kind: FileOperationKind) -> ConflictAnswer {
        ConflictDialog(info: info, kind: kind).run()
    }

    func resolveConflict(
        _ info: ConflictInfo, kind: FileOperationKind, window: AnyObject?, job: FileJob, completion: @escaping (ConflictAnswer) -> Void
    ) {
        let key = ObjectIdentifier(job)
        let began = ProcessInfo.processInfo.systemUptime
        let dialog = ConflictDialog(info: info, kind: kind)
        let constructed = ProcessInfo.processInfo.systemUptime
        conflicts[key] = dialog
        dialog.present(on: window as? NSWindow) { [weak self] answer in
            self?.conflicts.removeValue(forKey: key)
            completion(answer)
        }
        if Settings.isTesting {
            let line = String(
                format: "construct=%.3fms beginSheet=%.3fms", (constructed - began) * 1000,
                (ProcessInfo.processInfo.systemUptime - constructed) * 1000)
            DispatchQueue.global(qos: .utility).async {
                try? line.write(toFile: NSTemporaryDirectory() + "porpoise-conflict-phases.txt", atomically: true, encoding: .utf8)
            }
        }
    }

    func cancelConflict(for job: FileJob) {
        let key = ObjectIdentifier(job)
        conflicts[key]?.cancel()
        if let alert = diskFullAlerts.removeValue(forKey: key) {
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
            alert.window.orderOut(nil)
        }
    }

    func resolveDiskFull(destination: URL?, neededBytes: Int64, window: AnyObject?, job: FileJob, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(destination?.lastPathComponent ?? "The destination") is full."
        alert.informativeText =
            "Free space for “\(job.sources.first?.lastPathComponent ?? "this item")” (up to \(FileFormat.size(neededBytes))), then try again. Finished files stay in place."
        alert.addButton(withTitle: "Try Again"); alert.addButton(withTitle: "Stop")
        let key = ObjectIdentifier(job)
        diskFullAlerts[key] = alert
        let owner = window as? NSWindow
        if owner == nil { ActivityWindowController.shared.show() }
        guard let owner = owner ?? ActivityWindowController.shared.window else { completion(false); return }
        alert.beginSheetModal(for: owner) { [weak self] response in
            self?.diskFullAlerts.removeValue(forKey: key)
            completion(response == .alertFirstButtonReturn)
        }
    }

    func showTransferErrors(_ activity: Activity, window: AnyObject?) {
        let count = max(1, activity.failedSources.count)
        let listHeight = min(196, CGFloat(activity.errors.count) * 28)
        let height = 138 + listHeight
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Transfer Errors"
        sheet.isReleasedWhenClosed = false
        sheet.contentView = ConflictBackdropView(frame: CGRect(x: 0, y: 0, width: 560, height: height))
        func label(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight); field.textColor = Theme.windowText
            field.frame = CGRect(x: 20, y: y, width: 520, height: 32)
            sheet.contentView?.addSubview(field)
        }
        label(
            "\(count) \(count == 1 ? "item couldn’t" : "items couldn’t") be \(activity.kind == .move ? "moved" : "copied")", y: height - 50, size: 13,
            weight: .semibold)
        label("Finished files stay in place. Try Again retries the items that failed.", y: height - 82, size: 12)
        let scroll = NSScrollView(frame: CGRect(x: 20, y: 54, width: 520, height: listHeight))
        scroll.hasVerticalScroller = activity.errors.count > 7
        scroll.drawsBackground = false
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 6; scroll.layer?.borderWidth = 1
        Theme.whenChanged(scroll) { [weak scroll] in
            scroll?.layer?.backgroundColor = Theme.viewBackground.cgColor
            scroll?.layer?.borderColor = Theme.frame.cgColor
        }
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 504, height: CGFloat(activity.errors.count) * 28))
        for (index, error) in activity.errors.enumerated() {
            let y = document.bounds.height - CGFloat(index + 1) * 28
            let source = activity.failedSources[safe: index] ?? activity.failedSources.first
            let icon = NSImageView(frame: CGRect(x: 8, y: y + 6, width: 16, height: 16))
            icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: "Couldn't copy")
            icon.contentTintColor = Theme.transferDanger
            document.addSubview(icon)
            let path = NSTextField(labelWithString: source?.lastPathComponent ?? "Item \(index + 1)")
            path.font = .systemFont(ofSize: 11); path.lineBreakMode = .byTruncatingMiddle
            path.frame = CGRect(x: 32, y: y + 6, width: 150, height: 16); path.toolTip = source?.absoluteString
            document.addSubview(path)
            let reason = NSTextField(labelWithString: Self.reason(error))
            reason.font = .systemFont(ofSize: 11); reason.textColor = Theme.windowTextInactive
            reason.lineBreakMode = .byTruncatingTail; reason.alignment = .right
            reason.frame = CGRect(x: 190, y: y + 6, width: 236, height: 16); reason.toolTip = error
            document.addSubview(reason)
            if let source, Self.reason(error) != "No longer exists" {
                let reveal = ClosureButton(title: "Reveal") { _ in AppDelegate.shared.newWindow(at: source.deletingLastPathComponent()) }
                reveal.isBordered = false; reveal.font = .systemFont(ofSize: 11); reveal.contentTintColor = Theme.activeText
                reveal.frame = CGRect(x: 436, y: y + 2, width: 60, height: 24)
                document.addSubview(reveal)
            }
        }
        let list = TransferErrorListView(frame: scroll.frame)
        scroll.frame.origin = .zero
        scroll.documentView = document
        list.addSubview(scroll); sheet.contentView?.addSubview(list)
        let owner = window as? NSWindow
        if owner == nil { ActivityWindowController.shared.show() }
        guard let owner = owner ?? ActivityWindowController.shared.window else { return }
        func button(_ title: String, x: CGFloat, primary: Bool, action: @escaping () -> Void) {
            let button = TransferErrorActionButton(title: title, action: action)
            button.primary = primary; button.bezelStyle = .rounded
            button.keyEquivalent = primary ? "\r" : "\u{1b}"
            button.frame = CGRect(x: x, y: 14, width: 100, height: 28)
            sheet.contentView?.addSubview(button)
        }
        button("Skip", x: 326, primary: false) { [weak owner, weak sheet] in
            guard let owner, let sheet else { return }
            owner.endSheet(sheet); sheet.orderOut(nil)
        }
        button("Try Again", x: 436, primary: true) { [weak owner, weak sheet] in
            guard let owner, let sheet else { return }
            owner.endSheet(sheet); sheet.orderOut(nil)
            FileOperationsController.shared.retry(activity, window: owner)
        }
        owner.beginSheet(sheet)
    }

    private static func reason(_ error: String) -> String {
        let lower = error.lowercased()
        if lower.contains("no such file") || lower.contains("no longer there") { return "No longer exists" }
        if lower.contains("permission denied") || lower.contains("operation not permitted") || lower.contains("don’t have permission") {
            return "Permission denied"
        }
        if lower.contains("file name too long") || lower.contains("name too long") { return "Name too long for this disk" }
        if lower.contains("no space left") || lower.contains("disk full") { return "Disk full" }
        if lower.contains("locked") || lower.contains("resource busy") { return "File is locked" }
        if lower.contains("connection") || lower.contains("network") || lower.contains("timed out") { return "Lost connection" }
        return error
    }

    func jobStarted(_ job: FileJob) {
        if Settings.isTesting, let delay = ProcessInfo.processInfo.environment["PORPOISE_TRANSFER_PREPARATION_DELAY"].flatMap(Double.init) {
            job.inventoryDelay = min(0.01, max(0, delay))
        }
        if Settings.isTesting, let delay = ProcessInfo.processInfo.environment["PORPOISE_TRANSFER_DELAY"].flatMap(Double.init) {
            job.allowsClone = false
            job.resumableSize = 1
            job.chunkDelay = min(1, max(0, delay))
        }
        jobsPanel.add(job)
    }
    func jobProgressed(_ job: FileJob, _ progress: JobProgress) { jobsPanel.update(job, progress) }
    func jobFinished(_ job: FileJob) {
        jobsPanel.finish(job)
        DispatchQueue.main.async {
            guard let activity = FileOperationsController.shared.activities.first(where: { $0.job === job || $0.controlJob === job }),
                activity.state == .completed
            else { return }
            let owner = (activity.originWindow as? NSWindow)?.windowController as? MainWindowController
            owner?.view.statusBar.showMessage(TransferSummary.text(activity), duration: 4)
            NSAccessibility.post(
                element: owner?.window ?? NSApp, notification: .announcementRequested,
                userInfo: [.announcement: activity.title + ". " + activity.statusText, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    func showAuthorizationError(_ msg: String) {
        let e = NSAlert()
        e.alertStyle = .warning
        guard msg.contains("Operation not permitted") else { e.messageText = msg; e.runModal(); return }
        // Blocked by macOS's privacy protection: name the switch that's off, and open its list.
        if PrivilegedHelper.isEnabled, PrivilegedHelper.hasFullDiskAccess != true {
            DispatchQueue.global(qos: .userInitiated).async { _ = PrivilegedHelper.checkFullDiskAccess(timeout: 3) }  // lists it
            e.messageText = "Switch on Porpoise Helper under Full Disk Access"
            e.informativeText =
                "Porpoise Helper does the work on items that belong to the system. macOS lets it into "
                + "your Trash and other private folders once it's switched on (next to Porpoise in the same list). Then try again."
        } else {
            e.messageText = "macOS blocked this"
            e.informativeText =
                "Check that Porpoise and Porpoise Helper are switched on under Full Disk Access (and Porpoise under App Management for apps), then try again."
        }
        e.addButton(withTitle: "Open Full Disk Access")
        e.addButton(withTitle: "Cancel")
        if e.runModal() == .alertFirstButtonReturn { SystemIntegration.openPrivacyPane("Privacy_AllFiles") }
    }
}

/// The system clipboard, shared with Finder. Test instances use a private one, so automated tests never replace
/// what the user copied.
final class SystemClipboard: FileClipboard {
    private let pasteboard: NSPasteboard =
        Settings.isTesting
        ? NSPasteboard(
            name: NSPasteboard.Name("app.porpoise.Porpoise.test-clipboard." + (ProcessInfo.processInfo.environment["PORPOISE_BRIDGE"] ?? "test")))
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

/// Uses the same explicit accent/default drawing as conflict sheets, including while the owner is inactive.
private final class TransferErrorActionButton: ConflictActionButton {
    private let perform: () -> Void
    init(title: String, action: @escaping () -> Void) {
        perform = action
        super.init(frame: .zero)
        self.title = title; target = self; self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform() }
}

private final class TransferErrorListView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Theme.viewBackground.setFill(); box.fill()
        Theme.frame.setStroke(); box.lineWidth = 1; box.stroke()
    }
}
