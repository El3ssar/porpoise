import AppKit
import PorpoiseServices

extension AppDelegate {
    /// Gives the services what only the app can do (dialogs, opening files), before anything uses them.
    func connectServices() {
        RemoteFS.askLogin = FTPLoginPrompt.ask
        FileOperationsController.shared.ui = FileOperationsDialogs()
        FileOperationsController.shared.clipboard = SystemClipboard()
        RemoteOpener.openFile = { NSWorkspace.shared.open($0) }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in PlacesModel.shared.refreshDevices() }
        }
        // Increase Contrast and the like change how the theme draws: redraw everything at once.
        nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            func redraw(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(redraw) }
            for w in NSApp.windows { w.contentView.map(redraw) }
        }
    }
}
