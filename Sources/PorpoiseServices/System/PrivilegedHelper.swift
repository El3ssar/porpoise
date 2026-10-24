import Foundation
import PorpoiseCore
import PorpoiseHelperKit
import Security
import ServiceManagement

/// Porpoise's helper for items that belong to the system or other users (see PorpoiseHelperProtocol).
///
/// Installed once, with the administrator's approval (password or Touch ID), into /Library/PrivilegedHelperTools with
/// a launchd job: outside the app, so app updates never affect it. Only a new helper binary (rare:
/// scripts/build-helper.sh) is installed again, once, the next time it's needed. Each action it does is approved by
/// the person (W-245): the helper asks, with Touch ID or the password, naming what it will do (`HelperTier`).
public enum PrivilegedHelper {
    /// The app invalidates cached approval synchronously when the screen sleeps/locks or the user switches away.
    public static func forgetAuthorization() { HelperAuthorization.shared.drop() }

    private static var bundled: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Porpoise Helper.app") }

    /// What the helper must be signed as: its identifier and Porpoise's own certificate (nil: Porpoise is unsigned).
    static var requirement: String? { CodeSigning.ownLeafCertificateHash().map(PorpoiseHelperInfo.helperRequirement) }

    /// Whether the user Porpoise runs as may use the helper (administrators only; it refuses everyone else).
    /// Standard users get macOS's administrator prompt for each action instead. Asked each time (one directory
    /// lookup): someone removed from the admin group meanwhile gets the prompt, not the helper's refusal.
    public static var isForThisUser: Bool { PorpoiseHelperInfo.isAdministrator(getuid()) }

    /// Installed, the same binary as the one in this app, and intact: signed as the helper, by Porpoise's certificate.
    public static var isEnabled: Bool {
        let installed = URL(fileURLWithPath: PorpoiseHelperInfo.installedApp)
        guard FileManager.default.fileExists(atPath: PorpoiseHelperInfo.installedPlist), let hash = codeHash(installed), let requirement
        else { return false }
        return hash == codeHash(bundled) && CodeSigning.isIntact(at: installed, requirement: requirement)
    }

    /// Installed, but not the one in this app (an update is ready).
    public static var isOutdated: Bool { FileManager.default.fileExists(atPath: PorpoiseHelperInfo.installedPlist) && !isEnabled }

    /// Installs (or updates) the helper. macOS shows its administrator dialog (password or Touch ID). True once the
    /// helper answers.
    @discardableResult
    public static func enable() -> Bool {
        // A helper that isn't Porpoise's own, intact, is never offered for root (the app's folder may be writable).
        guard !Settings.isTesting, isForThisUser, let hash = CodeSigning.ownLeafCertificateHash(), let requirement,
            CodeSigning.isIntact(at: bundled, requirement: requirement)
        else { return false }
        guard
            runAsAdministrator(
                script: installScript, arguments: [bundled.path, hash],
                prompt:
                    "Porpoise wants to install its helper, so it can change items that belong to the system when you approve each change."
            )
        else { return false }
        DispatchQueue.main.async { NotificationCenter.default.post(name: PrivacyAccess.statusChanged, object: nil) }
        guard isEnabled, ping(timeout: 4) else { return false }
        // Lists "Porpoise Helper" under Full Disk Access (switched off) so it's there to switch on.
        _ = checkFullDiskAccess(timeout: 4)
        return true
    }

    /// "Porpoise Helper" may read protected folders (the Trash): it's switched on under Full Disk Access. Read from
    /// macOS's permission list (Porpoise can, with its own Full Disk Access); nil if that can't be read.
    public static var hasFullDiskAccess: Bool? {
        // Listed by its bundle identifier, or by its path when macOS records it as a program.
        let service = "kTCCServiceSystemPolicyAllFiles"
        let value =
            PrivacyAccess.tccAuthValue(service: service, client: PorpoiseHelperInfo.helperIdentifier)
            ?? PrivacyAccess.tccAuthValue(service: service, client: PorpoiseHelperInfo.installedTool)
        return value.map { $0 >= 2 } ?? (PrivacyAccess.hasFullDiskAccess ? false : nil)
    }

    /// Asks the helper itself (which also lists it under Full Disk Access if it isn't yet).
    public static func checkFullDiskAccess(timeout: TimeInterval) -> Bool {
        guard !Settings.isTesting, let c = connection() else { return false }
        defer { c.invalidate() }
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var ok = false
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? PorpoiseHelperProtocol
        proxy?.checkFullDiskAccess { a in
            lock.lock(); ok = a; lock.unlock(); done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return ok
    }

    /// Run as root by `enable` with the bundled helper app as $1 and Porpoise's certificate hash as $2. Replace,
    /// never stack: an old job is stopped, the files are written atomically, then the job is loaded. Root's own copy
    /// is checked before it's used (the bundle could be swapped between the app's check and the copy), and the
    /// launchd job and the rights are written from this text, never from the app's folder.
    static var installScript: String {
        let dest = PorpoiseHelperInfo.installedApp
        let requirement = PorpoiseHelperInfo.helperRequirement(certificateHash: "$2")
        let rights = [HelperRights.standard, HelperRights.protected].map { right in
            "/usr/bin/security authorizationdb write \(right) >/dev/null <<'RIGHT'\n\(HelperRights.plist(right))RIGHT"
        }.joined(separator: "\n")
        return """
            set -e
            /usr/bin/printf '%s' "$2" | /usr/bin/grep -Eq '^[0-9A-F]{40}$'
            /bin/launchctl bootout system/\(PorpoiseHelperInfo.machService) 2>/dev/null || true
            /bin/mkdir -p /Library/PrivilegedHelperTools
            /bin/rm -rf "\(dest).new"
            /usr/bin/ditto "$1" "\(dest).new"
            /usr/sbin/chown -R root:wheel "\(dest).new"
            /bin/chmod -R go-w "\(dest).new"
            /usr/bin/codesign --verify --deep --strict -R "=\(requirement.replacingOccurrences(of: "\"", with: "\\\""))" "\(dest).new" || { /bin/rm -rf "\(dest).new"; exit 1; }
            /bin/rm -rf "\(dest)"
            /bin/mv "\(dest).new" "\(dest)"
            /bin/rm -f "\(PorpoiseHelperInfo.oldInstalledTool)"
            \(rights)
            /bin/cat > "\(PorpoiseHelperInfo.installedPlist).new" <<'PLIST'
            \(PorpoiseHelperInfo.launchdPlist)PLIST
            /usr/sbin/chown root:wheel "\(PorpoiseHelperInfo.installedPlist).new"
            /bin/chmod 0644 "\(PorpoiseHelperInfo.installedPlist).new"
            /bin/mv "\(PorpoiseHelperInfo.installedPlist).new" "\(PorpoiseHelperInfo.installedPlist)"
            /bin/launchctl bootstrap system "\(PorpoiseHelperInfo.installedPlist)"
            """
    }

    /// Run as root by `disable`: the job, the helper and its rights.
    static var removeScript: String {
        """
        /bin/launchctl bootout system/\(PorpoiseHelperInfo.machService) 2>/dev/null || true
        /bin/rm -f "\(PorpoiseHelperInfo.installedPlist)" "\(PorpoiseHelperInfo.oldInstalledTool)"
        /bin/rm -rf "\(PorpoiseHelperInfo.installedApp)"
        /usr/bin/security authorizationdb remove \(HelperRights.standard) >/dev/null 2>&1 || true
        /usr/bin/security authorizationdb remove \(HelperRights.protected) >/dev/null 2>&1 || true
        """
    }

    /// Removes the helper (Settings).
    public static func disable() {
        _ = runAsAdministrator(script: removeScript, arguments: [], prompt: "Porpoise wants to remove its helper.")
        NotificationCenter.default.post(name: PrivacyAccess.statusChanged, object: nil)
    }

    /// Earlier versions registered the helper through System Settings › Login Items, which macOS ties to one exact
    /// build: that registration is removed once (no prompt), it's replaced by the installed helper.
    public static func migrateFromLoginItems() {
        guard !Settings.isTesting, !Settings.store.bool(forKey: "helperMigrated") else { return }
        Settings.store.set(true, forKey: "helperMigrated")
        let old = SMAppService.daemon(plistName: "app.porpoise.Porpoise.helper.plist")
        if old.status != .notRegistered { try? old.unregister() }
    }

    /// Makes sure the helper is ready for an action that needs it: installs or updates it (one approval) if needed.
    /// False: cancelled, or it couldn't be installed.
    static func ensureOn() -> Bool {
        if isEnabled, ping(timeout: 4) { return true }
        return enable()
    }

    /// Runs `script` with /bin/sh as root after macOS's administrator dialog (password or Touch ID). Arguments are
    /// passed as $1, $2… (never into the script text). True if approved and the script ran.
    private static func runAsAdministrator(script: String, arguments: [String], prompt: String) -> Bool {
        typealias Exec =
            @convention(c) (
                AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
                UnsafePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
            ) -> OSStatus
        guard let sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
            let sym = dlsym(sec, "AuthorizationExecuteWithPrivileges")
        else { return false }
        let exec = unsafeBitCast(sym, to: Exec.self)
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else { return false }
        defer { AuthorizationFree(auth, [.destroyRights]) }
        // Every C string handed over must live until AuthorizationCopyRights returns.
        let ok: Bool = kAuthorizationRightExecute.withCString { right in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                prompt.withCString { text in
                    var item = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(
                        name: promptKey, valueLength: strlen(text),
                        value: UnsafeMutableRawPointer(mutating: text), flags: 0)
                    return withUnsafeMutablePointer(to: &item) { ip in
                        withUnsafeMutablePointer(to: &promptItem) { pp in
                            var rights = AuthorizationRights(count: 1, items: ip)
                            var env = AuthorizationEnvironment(count: 1, items: pp)
                            return AuthorizationCopyRights(auth, &rights, &env, [.interactionAllowed, .extendRights, .preAuthorize], nil)
                                == errAuthorizationSuccess
                        }
                    }
                }
            }
        }
        guard ok else { return false }
        let args = ["-c", script, "sh"] + arguments
        let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pipe: UnsafeMutablePointer<FILE>?
        let status = cArgs.withUnsafeBufferPointer { exec(auth, "/bin/sh", [], $0.baseAddress!, &pipe) }
        guard status == errAuthorizationSuccess else { return false }
        // The script's output ends when it exits: read to the end to wait for it.
        if let pipe {
            var buf = [CChar](repeating: 0, count: 256)
            while fgets(&buf, Int32(buf.count), pipe) != nil {}
            fclose(pipe)
        }
        return true
    }

    /// The code hash of a signed binary (what identifies the helper).
    static func codeHash(_ url: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
            let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    private static func connection() -> NSXPCConnection? {
        guard let req = CodeSigning.requirement(identifier: PorpoiseHelperInfo.helperIdentifier) else { return nil }
        let c = NSXPCConnection(machServiceName: PorpoiseHelperInfo.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: PorpoiseHelperProtocol.self)
        c.setCodeSigningRequirement(req)
        c.resume()
        return c
    }

    /// The helper starts and answers within `timeout` (it quits again as soon as the connection closes). Never waits
    /// longer: a helper that can't start must not freeze the window.
    static func ping(timeout: TimeInterval) -> Bool {
        guard !Settings.isTesting, let c = connection() else { return false }
        defer { c.invalidate() }
        let done = DispatchSemaphore(value: 0)
        let answered = NSLock()
        var ok = false
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? PorpoiseHelperProtocol
        proxy?.version { v in
            answered.lock(); ok = !v.isEmpty; answered.unlock(); done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        answered.lock(); defer { answered.unlock() }
        return ok
    }

    enum Outcome: Equatable {
        case done
        /// The person didn't approve: nothing ran.
        case cancelled
        /// A command ran and failed (its message).
        case failed(String)
        /// The helper couldn't be reached before anything ran: the caller can install it or ask for a password.
        case unavailable(String)
    }

    /// Runs one action as administrator (see PorpoiseHelperInfo.allowedTools): the helper asks the person to approve
    /// it, naming what it does, then runs the commands in order; lock flags are cleared best effort. Items moved to
    /// the paths in `handOver` (the Trash) become the person's. Checks first that the helper answers at all, so a
    /// broken one can't freeze the window.
    static func run(_ commands: [[String]], handOver: [String] = []) -> Outcome {
        // Test instances take commands from other processes (DebugBridge): they never get root.
        guard !Settings.isTesting else { return .unavailable("Test instances don't use Porpoise's helper.") }
        return diagnosed(runChecked(commands, handOver: handOver))
    }

    /// A failed run as a diagnostic event: its kind only, never the command, its paths or the helper's message.
    static func diagnosed(_ outcome: Outcome, store: DiagnosticStore = Diagnostics.shared) -> Outcome {
        switch outcome {
        case .done, .cancelled: break
        case .unavailable: store.record(.helperUnavailable, failure: .unavailable)
        case .failed: store.record(.helperFailed, failure: .unknown)
        }
        return outcome
    }

    private static func runChecked(_ commands: [[String]], handOver: [String]) -> Outcome {
        guard ping(timeout: 4) || ping(timeout: 4) else { return .unavailable("Porpoise's helper didn't answer.") }
        guard let c = connection() else { return .unavailable("This copy of Porpoise isn't signed, so its helper can't be used.") }
        guard let authorization = HelperAuthorization.shared.externalForm() else {
            return .unavailable("macOS didn't give Porpoise an authorization to ask with.")
        }
        defer { c.invalidate() }
        var failure: String?
        let proxy = c.synchronousRemoteObjectProxyWithErrorHandler { failure = $0.localizedDescription } as? PorpoiseHelperProtocol
        var result: (cancelled: Bool, message: String?) = (false, "Porpoise's helper didn't answer.")
        proxy?.perform(commands, authorization: authorization, handOver: handOver) { result = ($0, $1) }
        if let failure { return .unavailable(failure) }
        if result.cancelled { return .cancelled }
        return result.message.map(Outcome.failed) ?? .done
    }
}

/// Porpoise's own authorization, which the helper asks the person's approval for. Kept for 5 minutes, so a standard
/// approval (`HelperRights.standard`) covers the actions that follow; the app drops it sooner when the screen sleeps
/// or locks, or another user takes over the Mac. A protected right is asked for every time whatever it holds.
final class HelperAuthorization: @unchecked Sendable {
    static let shared = HelperAuthorization()
    private let lock = NSLock()
    private var current: (ref: AuthorizationRef, made: Date)?
    /// Seams for tests.
    var now: () -> Date = Date.init
    var make: () -> AuthorizationRef? = {
        var ref: AuthorizationRef?
        return AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess ? ref : nil
    }
    /// The authorization to send with a request, made again once it's older than a standard approval lasts.
    func externalForm() -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let c = current, now().timeIntervalSince(c.made) >= TimeInterval(HelperRights.standardTimeout) { free(c.ref); current = nil }
        if current == nil, let ref = make() { current = (ref, now()) }
        guard let ref = current?.ref else { return nil }
        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &form) == errAuthorizationSuccess else { return nil }
        return withUnsafeBytes(of: form.bytes) { Data($0) }
    }

    /// Forgets the authorization (and with it a standard approval).
    func drop() {
        lock.lock(); defer { lock.unlock() }
        if let c = current { free(c.ref) }
        current = nil
    }

    var holdsOne: Bool { lock.withLock { current != nil } }

    private func free(_ ref: AuthorizationRef) { AuthorizationFree(ref, [.destroyRights]) }
}
