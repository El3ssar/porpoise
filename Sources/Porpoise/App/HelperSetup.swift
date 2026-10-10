import AppKit
import PorpoiseServices

/// Installing the helper and asking it about Full Disk Access wait on it (seconds at worst): never on the main thread.
enum HelperSetup {
    /// Installs the helper if needed (macOS's administrator dialog), makes sure it's listed under Full Disk Access,
    /// then calls `done` on the main thread.
    static func install(then done: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            if !PrivilegedHelper.isEnabled { PrivilegedHelper.enable() }
            if PrivilegedHelper.isEnabled { _ = PrivilegedHelper.checkFullDiskAccess(timeout: 3) }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PrivacyAccess.statusChanged, object: nil)
                done?()
            }
        }
    }

    /// Opens the Full Disk Access list once the helper is in it (it's added the first time it asks).
    static func openFullDiskAccess() {
        DispatchQueue.global(qos: .userInitiated).async {
            if PrivilegedHelper.isEnabled { _ = PrivilegedHelper.checkFullDiskAccess(timeout: 3) }
            DispatchQueue.main.async { SystemIntegration.openPrivacyPane("Privacy_AllFiles") }
        }
    }
}
