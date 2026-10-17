import AppKit
import PorpoiseServices

extension AppDelegate {
    /// Gives the services what only the app can do (dialogs, opening files), before anything uses them.
    func connectServices() {
        if !Settings.isTesting || ProcessInfo.processInfo.environment["PORPOISE_TEST_INDEX_DIRECTORY"] != nil { SearchIndex.shared.start() }
        RemoteFS.askLogin = FTPLoginPrompt.ask
        FileOperationsController.shared.ui = FileOperationsDialogs()
        FileOperationsController.shared.clipboard = SystemClipboard()
        RemoteOpener.openFile = { NSWorkspace.shared.open($0) }
        DriveEditing.shared.openFile = { RemoteOpener.openFile($0) }
        // Something to decide (a conflict, a save refused): a calm line in the front window with the way to Activity.
        DriveEditing.shared.post = { [weak self] text, attention in
            guard attention, let w = self?.windows.first(where: { $0.window?.isKeyWindow == true }) ?? self?.windows.first else {
                return StatusCenter.post(text)
            }
            w.view.messageBar.show(text, error: false, action: "Review in Activity…") {
                w.view.messageBar.dismiss()
                ActivityWindowController.shared.show()
            }
            w.view.needsLayout = true
        }
        DriveEditing.shared.restoresAtLaunch = true
        // Test instances can show made-up cloud accounts (no network, no browser).
        if Settings.isTesting, ProcessInfo.processInfo.environment["PORPOISE_CLOUD_DEMO"] != nil {
            CloudAccounts.shared.backend = DemoCloudBackend()
        } else {
            CloudAccounts.shared.backend = MainActor.assumeIsolated { DriveCloudBackend(store: .shared) }
        }
        // Test instances can show offline states set by hand (the bridge's `cloud offline`).
        if Settings.isTesting, ProcessInfo.processInfo.environment["PORPOISE_OFFLINE_DEMO"] != nil {
            CloudOfflineHub.service = DemoOfflineService()
        } else {
            CloudOfflineHub.service = CloudOffline.shared
            CloudOffline.shared.removalDenial = { url in
                guard let entry = DriveEditing.shared.entry(for: url) else { return nil }
                return "“\(entry.name)” has an open edit session or changes not in Google Drive yet."
            }
            CloudOffline.shared.activate()
        }
        let nc = NSWorkspace.shared.notificationCenter
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
            Theme.lookChanged()
            for w in NSApp.windows { w.contentView?.redrawAll() }
        }
    }
}
