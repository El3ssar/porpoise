import AppKit
import PorpoiseServices

extension AppDelegate {
    /// Gives the services what only the app can do (dialogs, opening files), before anything uses them.
    @MainActor func connectServices() {
        if !Settings.isTesting || TestEnvironment.testIndexDirectory.isSet { SearchIndex.shared.start() }
        RemoteFS.askLogin = FTPLoginPrompt.ask
        RemoteFS.confirmHostKeyChange = HostKeyChangePrompt.ask
        // Shared ssh connections that a sleep or a network change left dead are dropped, so the next command reconnects.
        ConnectionMonitor.shared.start()
        FileOperationsController.shared.ui = FileOperationsDialogs()
        FileOperationsController.shared.clipboard = SystemClipboard()
        RemoteOpener.openFile = { url in MainActorDelivery.deliver { NSWorkspace.shared.open(url) } }
        CloudEditing.shared.openFile = { RemoteOpener.openFile($0) }
        // Something to decide (a conflict, a save refused): a calm line in the front window with the way to Activity.
        CloudEditing.shared.post = { [weak self] text, attention in
            MainActorDelivery.deliver { [weak self] in
                guard let self else { StatusCenter.post(text); return }
                self.postEditingMessage(text, attention: attention)
            }
        }
        NotificationCenter.default.addObserver(forName: CloudEditing.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EditDecisionMessage.closeIfDecided() }
        }
        CloudEditing.shared.restoresAtLaunch = true
        // Test instances can show made-up cloud accounts (no network, no browser).
        if Settings.isTesting, TestEnvironment.cloudDemo.isSet {
            CloudAccounts.shared.backend = DemoCloudBackend()
        } else {
            CloudAccounts.shared.backend = MainActor.assumeIsolated {
                CompositeCloudBackend([
                    .googleDrive: DriveCloudBackend(store: .shared), .dropbox: DropboxCloudBackend(store: .shared),
                    .oneDrive: OneDriveCloudBackend(store: .shared), .box: BoxCloudBackend(store: .shared),
                ])
            }
        }
        // Test instances can show offline states set by hand (the bridge's `cloud offline`).
        if Settings.isTesting, TestEnvironment.offlineDemo.isSet {
            CloudOfflineHub.service = DemoOfflineService()
        } else {
            CloudOfflineHub.service = CloudOffline.shared
            CloudOffline.shared.removalDenial = { url in
                guard let entry = CloudEditing.shared.entry(for: url) else { return nil }
                return "“\(entry.name)” has an open edit session or changes not in \(entry.provider.title) yet."
            }
            CloudOffline.shared.activate()
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in ConnectionMonitor.shared.systemDidWake() }
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in PlacesModel.shared.refreshDevices() }
        }
        // Phones are polled while Porpoise is in front only.
        PlacesModel.shared.isActive = NSApp.isActive
        for (n, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in PlacesModel.shared.isActive = active }
        }
        // Cloud accounts look for changes every little while in front only; back in front, changes made meanwhile in
        // the browser or on another device show without a reload.
        for (n, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in CloudAccounts.shared.backend?.setActive(active) }
        }
        // Increase Contrast and the like change how the theme draws: redraw everything at once.
        nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Theme.lookChanged()
                for w in NSApp.windows { w.contentView?.redrawAll() }
            }
        }
    }

    @MainActor private func postEditingMessage(_ text: String, attention: Bool) {
        guard attention, let w = windows.first(where: { $0.window?.isKeyWindow == true }) ?? windows.first else {
            return StatusCenter.post(text)
        }
        w.view.messageBar.show(text, error: false, action: "Review in Activity…") {
            w.view.messageBar.dismiss()
            ActivityWindowController.shared.show()
        }
        w.view.needsLayout = true
        EditDecisionMessage.shown(on: w.view.messageBar)
    }

}

/// The message bar line about an edit waiting for a decision (a conflict, a copy to save): it goes by itself once the
/// decision is made in Activity, instead of pointing there for nothing.
@MainActor enum EditDecisionMessage {
    private static weak var bar: MessageBar?
    private static var text = ""

    /// Whether an edit waits for a decision now.
    static var isWaiting: Bool { CloudEditing.shared.entries.contains { $0.mark == .conflict } }

    /// `bar` shows a line just posted: remembered if it is about a decision waiting.
    static func shown(on bar: MessageBar) {
        guard isWaiting else { return }
        self.bar = bar
        text = bar.text
    }

    static func closeIfDecided() {
        guard let bar, !bar.isHidden, bar.text == text, !isWaiting else { return }
        bar.dismiss()
        self.bar = nil
    }
}
