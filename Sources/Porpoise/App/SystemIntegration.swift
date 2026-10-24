import AppKit
import PorpoiseCore
import PorpoiseServices
import ServiceManagement
import UniformTypeIdentifiers

/// Standing in for Finder: default file browser (folders + "Show in Finder" requests) and privacy permissions.
enum SystemIntegration {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "app.porpoise.Porpoise" }

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

    /// Makes Porpoise (or Finder again) the file viewer other apps reveal files in, and the app that opens disks
    /// (`open /Volumes/…`, other apps opening a drive); macOS asks the user to confirm that. Opening folders themselves
    /// is asked for too, where macOS allows it: macOS 26 and later keep folders with Finder and refuse (paramErr),
    /// which isn't an error for the user, nor is declining macOS's question.
    static func setDefaultBrowser(_ on: Bool, done: @escaping (Error?) -> Void) {
        let viewer: CFString? = on ? bundleID as CFString : nil
        CFPreferencesSetValue("NSFileViewer" as CFString, viewer, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let app = on ? Bundle.main.bundleURL : URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        func expected(_ err: Error?) -> Bool {
            guard let e = err as NSError? else { return true }
            let code = (e.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? e.code
            return code == Int(paramErr) || code == Int(userCanceledErr) || e.code == NSUserCancelledError
        }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder) { folderErr in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .volume) { volumeErr in
                let err = [folderErr, volumeErr].first { !expected($0) } ?? nil
                DispatchQueue.main.async { done(err) }
            }
        }
    }

    /// Disks (`open /Volumes/…`, other apps opening a drive) open in Porpoise.
    static var opensDisks: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: .volume).flatMap { Bundle(url: $0)?.bundleIdentifier } == bundleID
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
        /// Where the items go (the app's windows; replaced in tests).
        var reveal: ([URL]) -> Void = { AppDelegate.shared.reveal($0) }

        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            let urls = Self.items(of: event)
            guard !urls.isEmpty else { return }
            reveal(urls)
        }

        /// The files of the event's direct object: one, or a list.
        static func items(of event: NSAppleEventDescriptor) -> [URL] {
            guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return [] }
            let n = direct.numberOfItems
            return n == 0 ? [direct.fileURLValue].compactMap { $0 } : (1...n).compactMap { direct.atIndex($0)?.fileURLValue }
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
                guard PrivilegedHelper.isForThisUser else {
                    return (nil, "For administrators only. Porpoise asks for an administrator's name and password when an action needs it.")
                }
                guard PrivilegedHelper.isEnabled else {
                    return (false, "Not set up. Click Allow… to install Porpoise Helper (your administrator password, once).")
                }
                return PrivilegedHelper.hasFullDiskAccess == false
                    ? (false, "Installed. Click Allow…, then switch Porpoise Helper on under Full Disk Access.")
                    : (true, "Allowed. Porpoise asks for Touch ID or your password before it changes system-owned items (such as App Store apps).")
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

    // MARK: Asked for when first needed

    /// The permissions the welcome doesn't ask for: each is asked for, with a word on why, the first time an action
    /// needs it. (The helper is installed by the first action on a system-owned item: `FileOperationsController.authorize`.)
    enum FirstNeed {
        static let askedAppManagementKey = "askedAppManagement"
        /// The App Management state, and the check that finds it out (replaced in tests).
        static var appManagementState: () -> PrivacyAccess.AccessState = { PrivacyAccess.appManagementState }
        static var checkAppManagement: (@escaping () -> Void) -> Void = { done in checkAppManagementInBackground(then: done) }

        /// Moving, trashing or deleting an app needs App Management (macOS stops one app changing another).
        static func touchesApps(_ kind: FileOperationKind, _ sources: [URL]) -> Bool {
            [.move, .trash, .delete].contains(kind) && sources.contains { $0.isFileURL && $0.pathExtension == "app" }
        }

        /// The first time apps are moved or deleted while App Management isn't known to be on: checks it (macOS lists
        /// Porpoise, switched off, and says so), and calls `explain` if it's off. Once only: after that, Settings › System.
        static func appManagement(_ kind: FileOperationKind, _ sources: [URL], explain: @escaping () -> Void) {
            guard touchesApps(kind, sources), appManagementState() != .allowed,
                !Settings.store.bool(forKey: askedAppManagementKey)
            else { return }
            Settings.store.set(true, forKey: askedAppManagementKey)
            checkAppManagement { if appManagementState() == .denied { explain() } }
        }

        /// The first visit to Network (and each one while it's off): macOS asks whether Porpoise may look for servers;
        /// `denied` runs when the answer is no.
        static func localNetwork(denied: @escaping () -> Void) {
            guard !LocalNetworkAccess.shared.isAllowed else { return }
            LocalNetworkAccess.shared.request { allowed in if !allowed { denied() } }
        }
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
