import AppKit
import ServiceManagement
import Security
import SQLite3
import UniformTypeIdentifiers
import PorpoiseServices

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
        m.setEventHandler(h, andSelector: #selector(RevealHandler.handle(_:reply:)),
                          forEventClass: AEEventClass(kAEMiscStandards), andEventID: AEEventID(kAEMakeObjectsVisible))
        m.setEventHandler(h, andSelector: #selector(RevealHandler.handle(_:reply:)),
                          forEventClass: fourCC("FNDR"), andEventID: fourCC("show"))
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    final class RevealHandler: NSObject {
        static let shared = RevealHandler()
        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
            var urls: [URL] = []
            let n = direct.numberOfItems
            if n == 0 { if let u = direct.fileURLValue { urls.append(u) } }
            else { urls = (1...n).compactMap { direct.atIndex($0)?.fileURLValue } }
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
        Permission(title: "Full Disk Access", anchor: "Privacy_AllFiles", status: {
            hasFullDiskAccess ? (true, "Allowed. Protected folders (Trash, Mail, other apps' data) can be shown.")
                : (false, "Not allowed. Needed to show protected folders such as the Trash. Add Porpoise with the + button.")
        }, request: nil),
        Permission(title: "App Management", anchor: "Privacy_AppBundles", status: {
            switch appManagementState {
            case .allowed: return (true, "Allowed. Porpoise can update, move and delete other apps.")
            case .denied: return (false, "Not allowed yet. Click Request Access: macOS adds Porpoise to the list, then switch it on.")
            case .unknown: return (nil, "Lets Porpoise update, move and delete other apps. Click Request Access, then switch Porpoise on.")
            }
        }, request: ("Request Access", { requestAppManagement() })),
        Permission(title: "Administrator Actions", anchor: "", status: {
            guard PrivilegedHelper.isEnabled else {
                return (false, "Not set up. Porpoise installs its helper the first time it needs it (one approval).")
            }
            return PrivilegedHelper.hasFullDiskAccess == false
                ? (false, "Installed. Switch on Porpoise Helper under Full Disk Access to let it empty the Trash.")
                : (true, "Allowed. Porpoise empties the Trash and changes system-owned items (such as App Store apps) without asking.")
        }, request: ("Set Up…", {
            if !PrivilegedHelper.isEnabled { PrivilegedHelper.enable() }
            if PrivilegedHelper.isEnabled { _ = PrivilegedHelper.checkFullDiskAccess(timeout: 3); openPrivacyPane("Privacy_AllFiles") }
        }), open: { openPrivacyPane("Privacy_AllFiles") }),
        Permission(title: "Local Network", anchor: "Privacy_LocalNetwork", status: {
            LocalNetworkAccess.shared.isAllowed ? (true, "Allowed. File servers on your network appear under Network.")
                : (nil, "Lets Porpoise list the file servers and shared folders on your network.")
        }, request: ("Allow…", { LocalNetworkAccess.shared.request { _ in } })),
    ]

    /// The system-wide privacy (TCC) database.
    private static let tccDatabase = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// TCC's own database is readable only with Full Disk Access.
    static var hasFullDiskAccess: Bool {
        let fd = open(tccDatabase, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    enum AccessState: String { case allowed, denied, unknown }

    /// Last result of the App Management check (kept, since checking while denied shows a notification each time).
    private static var lastAppManagement: AccessState {
        get { Settings.store.string(forKey: "appManagement").flatMap(AccessState.init(rawValue:)) ?? .unknown }
        set { Settings.store.set(newValue.rawValue, forKey: "appManagement") }
    }
    static var appManagementState: AccessState {
        // With Full Disk Access the system's permission database can be read directly (exact, no side effects).
        if let v = tccAuthValue(service: "kTCCServiceSystemPolicyAppBundles") { return v >= 2 ? .allowed : .denied }
        return lastAppManagement
    }

    /// Everything Porpoise uses is available (each permission granted, the helper switched on).
    static var allPermissionsGranted: Bool {
        hasFullDiskAccess && appManagementState == .allowed && PrivilegedHelper.isEnabled
            && PrivilegedHelper.hasFullDiskAccess == true && LocalNetworkAccess.shared.isAllowed
    }

    /// auth_value of Porpoise's row for a TCC service in the system database (2 = allowed), nil if unreadable or absent.
    static func tccAuthValue(service: String, client: String? = nil) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(tccDatabase, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT auth_value FROM access WHERE service = ? AND client = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, service, -1, transient)
        sqlite3_bind_text(stmt, 2, client ?? bundleID, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : nil
    }

    /// A harmless change to another app (an empty file, removed at once). macOS checks App Management on it:
    /// if Porpoise isn't allowed, it is added to the list (switched off) and macOS shows a notification.
    static func requestAppManagement(then done: (() -> Void)? = nil) { checkAppManagementInBackground(openSettingsIfDenied: true, then: done) }

    /// Posted on the main queue when a background permission check has finished.
    static let statusChanged = Notification.Name("PorpoisePermissionStatusChanged")

    /// The App Management check, off the main thread: it scans /Applications and reads code signatures.
    /// Silent unless `openSettingsIfDenied`.
    static func checkAppManagementInBackground(openSettingsIfDenied: Bool = false, then done: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            checkAppManagement(openSettingsIfDenied: openSettingsIfDenied)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: statusChanged, object: nil)
                done?()
            }
        }
    }

    static func checkAppManagement(openSettingsIfDenied: Bool) {
        let fm = FileManager.default
        let apps = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)) ?? []
        let mine = Bundle.main.bundleURL.standardizedFileURL
        // App Management protects signed apps only, so check against one with a developer signature.
        guard let target = apps.first(where: { u in
            u.pathExtension == "app" && u.standardizedFileURL != mine
                && (try? fm.attributesOfItem(atPath: u.path)[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
                && teamIdentifier(of: u) != nil
        }) else { if openSettingsIfDenied { DispatchQueue.main.async { openPrivacyPane("Privacy_AppBundles") } }; return }
        // An empty file created and removed at once inside the other app (its signed contents are untouched).
        let probe = target.appendingPathComponent("Contents/.porpoise-access-check").path
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 { close(fd); unlink(probe); lastAppManagement = .allowed }
        else { lastAppManagement = (errno == EPERM || errno == EACCES) ? .denied : .unknown }
        if lastAppManagement != .allowed && openSettingsIfDenied {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openPrivacyPane("Privacy_AppBundles") }
        }
    }

    static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return d[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func openPrivacyPane(_ anchor: String) {
        // The Privacy & Security extension's URL (macOS 13+) opens the exact list, e.g. Full Disk Access.
        guard let u = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(u, configuration: config)
    }
}
