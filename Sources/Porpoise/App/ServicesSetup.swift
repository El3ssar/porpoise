import AppKit
import PorpoiseServices

extension AppDelegate {
    /// Gives the services what only the app can do (dialogs, opening files), before anything uses them.
    func connectServices() {
        RemoteFS.askLogin = FTPLoginPrompt.ask
        FileOperationsController.shared.ui = FileOperationsDialogs()
        FileOperationsController.shared.clipboard = SystemClipboard()
    }
}
