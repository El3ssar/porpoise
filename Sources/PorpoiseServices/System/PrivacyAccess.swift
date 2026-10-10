import Foundation
import SQLite3
import Security

/// macOS's privacy permissions (TCC) as far as Porpoise can read them without asking: Full Disk Access and App
/// Management. Asking for them and opening System Settings is up to the app.
public enum PrivacyAccess {
    /// Posted on the main queue when a background permission check has finished.
    public static let statusChanged = Notification.Name("PorpoisePermissionStatusChanged")

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "app.porpoise.Porpoise" }

    /// The system-wide privacy (TCC) database.
    /// (A variable so tests can point it at a database of their own.)
    nonisolated(unsafe) static var tccDatabase = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// TCC's own database is readable only with Full Disk Access.
    public static var hasFullDiskAccess: Bool {
        let fd = open(tccDatabase, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    public enum AccessState: String { case allowed, denied, unknown }

    /// Last result of the App Management check (kept, since checking while denied shows a notification each time).
    private static var lastAppManagement: AccessState {
        get { Settings.store.string(forKey: "appManagement").flatMap(AccessState.init(rawValue:)) ?? .unknown }
        set { Settings.store.set(newValue.rawValue, forKey: "appManagement") }
    }
    public static var appManagementState: AccessState {
        // With Full Disk Access the system's permission database can be read directly (exact, no side effects).
        if let v = tccAuthValue(service: "kTCCServiceSystemPolicyAppBundles") { return v >= 2 ? .allowed : .denied }
        return lastAppManagement
    }

    /// auth_value of Porpoise's row for a TCC service in the system database (2 = allowed), nil if unreadable or absent.
    public static func tccAuthValue(service: String, client: String? = nil) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(tccDatabase, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT auth_value FROM access WHERE service = ? AND client = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, service, -1, transient)
        sqlite3_bind_text(stmt, 2, client ?? bundleID, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : nil
    }

    /// The App Management check (slow: it scans /Applications and reads code signatures; call off the main thread).
    /// A harmless change to another app (an empty file, removed at once): macOS checks App Management on it, and if
    /// Porpoise isn't allowed, adds it to the list (switched off) and shows a notification. Returns the answer (also
    /// kept for `appManagementState`), or nil if there is no app to check against.
    public static func checkAppManagement() -> AccessState? {
        let fm = FileManager.default
        let apps = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)) ?? []
        let mine = Bundle.main.bundleURL.standardizedFileURL
        // App Management protects signed apps only, so check against one with a developer signature.
        guard
            let target = apps.first(where: { u in
                u.pathExtension == "app" && u.standardizedFileURL != mine
                    && (try? fm.attributesOfItem(atPath: u.path)[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
                    && teamIdentifier(of: u) != nil
            })
        else { return nil }
        // An empty file created and removed at once inside the other app (its signed contents are untouched).
        let probe = target.appendingPathComponent("Contents/.porpoise-access-check").path
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            close(fd); unlink(probe); lastAppManagement = .allowed
        } else {
            lastAppManagement = (errno == EPERM || errno == EACCES) ? .denied : .unknown
        }
        return lastAppManagement
    }

    private static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let d = info as? [String: Any]
        else { return nil }
        return d[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
