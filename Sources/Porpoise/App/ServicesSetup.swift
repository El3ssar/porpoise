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
        // Test instances can show made-up cloud accounts (no network, no browser).
        if Settings.isTesting, ProcessInfo.processInfo.environment["PORPOISE_CLOUD_DEMO"] != nil {
            CloudAccounts.shared.backend = DemoCloudBackend()
        }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in PlacesModel.shared.refreshDevices() }
        }
        // Phones are polled while Porpoise is in front only.
        for (n, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in PlacesModel.shared.isActive = active }
        }
        // Increase Contrast and the like change how the theme draws: redraw everything at once.
        nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            Theme.lookChanged()
            for w in NSApp.windows { w.contentView?.redrawAll() }
        }
    }
}
