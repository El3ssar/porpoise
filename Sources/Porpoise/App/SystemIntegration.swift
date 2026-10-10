import AppKit
import PorpoiseServices
import ServiceManagement
import UniformTypeIdentifiers

/// Standing in for Finder: default file browser (folders + "Show in Finder" requests) and privacy permissions.
enum SystemIntegration {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "app.porpoise.Porpoise" }
    private static let finderID = "com.apple.finder"

    // MARK: Default file browser

    /// Apps' "Reveal in Finder" / "Show in Finder" go to the app named by the global NSFileViewer default.
    static var fileViewer: String? {
        CFPreferencesCopyValue("NSFileViewer" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    static var folderHandler: String? {
        NSWorkspace.shared.urlForApplication(toOpen: .folder).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Other apps' "Show in Finder" opens Porpoise.
    static var isDefaultBrowser: Bool { fileViewer == bundleID }

    /// Makes Porpoise (or Finder again) the file viewer other apps reveal files in. Opening folders themselves (the
    /// Dock, the desktop, Open With) is also handed over where macOS allows it; macOS 26 and later keep that with
    /// Finder and refuse the change (paramErr), which isn't an error for the user.
    static func setDefaultBrowser(_ on: Bool, done: @escaping (Error?) -> Void) {
        let viewer: CFString? = on ? bundleID as CFString : nil
        CFPreferencesSetValue("NSFileViewer" as CFString, viewer, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let app = on ? Bundle.main.bundleURL : URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder) { err in
            let refused = ((err as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(paramErr)
            DispatchQueue.main.async { done(refused ? nil : err) }
        }
    }

    /// macOS lets Porpoise open folders from the Dock and the desktop too (not on macOS 26 and later).
    static var opensFolders: Bool { folderHandler == bundleID }

    /// Handles Finder's reveal Apple Events, which NSWorkspace sends to the NSFileViewer app.
    static func installRevealHandlers() {
        let m = NSAppleEventManager.shared()
        let h = RevealHandler.shared
        // 'misc'/'mvis' (make objects visible) and Finder's 'FNDR'/'show'.
        m.setEventHandler(
            h, andSelector: #selector(RevealHandler.handle(_:reply:)),
            forEventClass: AEEventClass(kAEMiscStandards), andEventID: AEEventID(kAEMakeObjectsVisible))
        m.setEventHandler(
            h, andSelector: #selector(RevealHandler.handle(_:reply:)),
            forEventClass: fourCC("FNDR"), andEventID: fourCC("show"))
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    final class RevealHandler: NSObject {
        static let shared = RevealHandler()
        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
            var urls: [URL] = []
            let n = direct.numberOfItems
            if n == 0 { if let u = direct.fileURLValue { urls.append(u) } } else { urls = (1...n).compactMap { direct.atIndex($0)?.fileURLValue } }
            guard !urls.isEmpty else { return }
            AppDelegate.shared.reveal(urls)
        }
    }

    // MARK: Privacy permissions

    struct Permission {
        let title: String
        let anchor: String
        /// (granted?, explanation); nil = unknown.
        let status: () -> (Bool?, String)
        /// Button title and what it does (nil = just open System Settings).
        let request: (title: String, run: () -> Void)?
        /// Where it is in System Settings (default: the Privacy & Security list named by `anchor`).
        var open: (() -> Void)? = nil
    }

    static let permissions: [Permission] = [
        Permission(
            title: "Full Disk Access", anchor: "Privacy_AllFiles",
            status: {
                PrivacyAccess.hasFullDiskAccess
                    ? (true, "Allowed. Protected folders (Trash, Mail, other apps' data) can be shown.")
                    : (
                        false,
                        "Not allowed. Switch Porpoise on in the list (drag it in if it isn't there): it's needed for protected folders such as the Trash."
                    )
            }, request: nil),
        Permission(
            title: "App Management", anchor: "Privacy_AppBundles",
            status: {
                switch PrivacyAccess.appManagementState {
                case .allowed: return (true, "Allowed. Porpoise can update, move and delete other apps.")
                case .denied: return (false, "Not allowed. Click Allow…, then switch Porpoise on in the list that opens.")
                case .unknown: return (nil, "Lets Porpoise update, move and delete other apps. Click Allow…, then switch Porpoise on.")
                }
            }, request: ("Allow…", { requestAppManagement() })),
        Permission(
            title: "Administrator Actions", anchor: "",
            status: {
                guard PrivilegedHelper.isEnabled else {
                    return (false, "Not set up. Click Allow… to install Porpoise Helper (your administrator password, once).")
                }
                return PrivilegedHelper.hasFullDiskAccess == false
                    ? (false, "Installed. Click Allow…, then switch Porpoise Helper on under Full Disk Access.")
                    : (true, "Allowed. Porpoise empties the Trash and changes system-owned items (such as App Store apps) without asking.")
            },
            request: (
                "Allow…",
                {
                    HelperSetup.install { if PrivilegedHelper.isEnabled { openPrivacyPane("Privacy_AllFiles") } }
                }
            ), open: { openPrivacyPane("Privacy_AllFiles") }),
        Permission(
            title: "Local Network", anchor: "Privacy_LocalNetwork",
            status: {
                LocalNetworkAccess.shared.isAllowed
                    ? (true, "Allowed. File servers on your network appear under Network.")
                    : (nil, "Lets Porpoise list the file servers and shared folders on your network.")
            }, request: ("Allow…", { LocalNetworkAccess.shared.request { _ in } })),
    ]

    /// Everything Porpoise uses is available (each permission granted, the helper switched on).
    static var allPermissionsGranted: Bool {
        PrivacyAccess.hasFullDiskAccess && PrivacyAccess.appManagementState == .allowed && PrivilegedHelper.isEnabled
            && PrivilegedHelper.hasFullDiskAccess == true && LocalNetworkAccess.shared.isAllowed
    }

    /// A harmless change to another app (an empty file, removed at once). macOS checks App Management on it:
    /// if Porpoise isn't allowed, it is added to the list (switched off) and macOS shows a notification.
    static func requestAppManagement(then done: (() -> Void)? = nil) { checkAppManagementInBackground(openSettingsIfDenied: true, then: done) }

    /// The App Management check, off the main thread: it scans /Applications and reads code signatures.
    /// Silent unless `openSettingsIfDenied`.
    static func checkAppManagementInBackground(openSettingsIfDenied: Bool = false, then done: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            checkAppManagement(openSettingsIfDenied: openSettingsIfDenied)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PrivacyAccess.statusChanged, object: nil)
                done?()
            }
        }
    }

    static func checkAppManagement(openSettingsIfDenied: Bool) {
        let state = PrivacyAccess.checkAppManagement()
        guard openSettingsIfDenied else { return }
        if state == nil {
            DispatchQueue.main.async { openPrivacyPane("Privacy_AppBundles") }
        } else if state != .allowed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openPrivacyPane("Privacy_AppBundles") }
        }
    }

    static func openPrivacyPane(_ anchor: String) {
        // The Privacy & Security extension's URL (macOS 13+) opens the exact list, e.g. Full Disk Access.
        guard let u = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(u, configuration: config)
    }
}
