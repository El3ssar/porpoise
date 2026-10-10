import AppKit
import Network
import PorpoiseCore
import ServiceManagement

/// Porpoise's helper for items that belong to the system or other users (see PorpoiseHelperProtocol).
///
/// Installed once, with the administrator's approval (password or Touch ID), into /Library/PrivilegedHelperTools with
/// a launchd job: outside the app, so app updates never affect it. After that it works without asking. Only a new
/// helper binary (rare: scripts/build-helper.sh) is installed again, once, the next time it's needed.
enum PrivilegedHelper {
    private static var bundled: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PorpoiseHelper") }
    private static var bundledPlist: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/app.porpoise.helper.plist") }

    /// Installed, and the same binary as the one in this app.
    static var isEnabled: Bool {
        guard FileManager.default.fileExists(atPath: PorpoiseHelperInfo.installedPlist),
              let installed = codeHash(URL(fileURLWithPath: PorpoiseHelperInfo.installedTool)) else { return false }
        return installed == codeHash(bundled)
    }

    /// Installs (or updates) the helper. macOS shows its administrator dialog (password or Touch ID). True once the
    /// helper answers.
    @discardableResult
    static func enable() -> Bool {
        guard !Settings.isTesting, FileManager.default.fileExists(atPath: bundled.path),
              FileManager.default.fileExists(atPath: bundledPlist.path) else { return false }
        // Replace, never stack: an old job is stopped, the files are written atomically, then the job is loaded.
        let script = """
            set -e
            /bin/launchctl bootout system/\(PorpoiseHelperInfo.machService) 2>/dev/null || true
            /bin/mkdir -p /Library/PrivilegedHelperTools
            /usr/bin/install -o root -g wheel -m 0544 "$1" "\(PorpoiseHelperInfo.installedTool).new"
            /bin/mv -f "\(PorpoiseHelperInfo.installedTool).new" "\(PorpoiseHelperInfo.installedTool)"
            /usr/bin/install -o root -g wheel -m 0644 "$2" "\(PorpoiseHelperInfo.installedPlist)"
            /bin/launchctl bootstrap system "\(PorpoiseHelperInfo.installedPlist)"
            """
        guard runAsAdministrator(script: script, arguments: [bundled.path, bundledPlist.path],
                                 prompt: "Porpoise wants to install its helper, so it can empty the Trash and change items that belong to the system without asking again.")
        else { return false }
        NotificationCenter.default.post(name: SystemIntegration.statusChanged, object: nil)
        return isEnabled && ping(timeout: 3)
    }

    /// Removes the helper (Settings).
    static func disable() {
        _ = runAsAdministrator(script: """
            /bin/launchctl bootout system/\(PorpoiseHelperInfo.machService) 2>/dev/null || true
            /bin/rm -f "\(PorpoiseHelperInfo.installedPlist)" "\(PorpoiseHelperInfo.installedTool)"
            """, arguments: [], prompt: "Porpoise wants to remove its helper.")
        NotificationCenter.default.post(name: SystemIntegration.statusChanged, object: nil)
    }

    /// Earlier versions registered the helper through System Settings › Login Items, which macOS ties to one exact
    /// build: that registration is removed once (no prompt), it's replaced by the installed helper.
    static func migrateFromLoginItems() {
        guard !Settings.isTesting, !Settings.store.bool(forKey: "helperMigrated") else { return }
        Settings.store.set(true, forKey: "helperMigrated")
        let old = SMAppService.daemon(plistName: "app.porpoise.Porpoise.helper.plist")
        if old.status != .notRegistered { try? old.unregister() }
    }

    /// Makes sure the helper is ready for an action that needs it: installs or updates it (one approval) if needed.
    /// False: cancelled, or it couldn't be installed.
    static func ensureOn(window: NSWindow?) -> Bool {
        if isEnabled, ping(timeout: 4) { return true }
        return enable()
    }

    /// Runs `script` with /bin/sh as root after macOS's administrator dialog (password or Touch ID). Arguments are
    /// passed as $1, $2… (never into the script text). True if approved and the script ran.
    private static func runAsAdministrator(script: String, arguments: [String], prompt: String) -> Bool {
        typealias Exec = @convention(c) (AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
                                         UnsafePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?) -> OSStatus
        guard let sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let sym = dlsym(sec, "AuthorizationExecuteWithPrivileges") else { return false }
        let exec = unsafeBitCast(sym, to: Exec.self)
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else { return false }
        defer { AuthorizationFree(auth, [.destroyRights]) }
        let ok: Bool = kAuthorizationRightExecute.withCString { right in
            prompt.withCString { text in
                var item = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
                var promptItem = AuthorizationItem(name: kAuthorizationEnvironmentPrompt, valueLength: strlen(text),
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
        guard ok else { return false }
        let args = ["-c", script, "sh"] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
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
    private static func codeHash(_ url: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
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
        proxy?.version { v in answered.lock(); ok = !v.isEmpty; answered.unlock(); done.signal() }
        _ = done.wait(timeout: .now() + timeout)
        answered.lock(); defer { answered.unlock() }
        return ok
    }

    /// Hands items Porpoise moved into the Trash to the user, so emptying it needs no administrator rights (best effort).
    static func takeOwnership(of paths: [String]) {
        guard !paths.isEmpty, isEnabled, !Settings.isTesting, let c = connection() else { return }
        defer { c.invalidate() }
        let proxy = c.synchronousRemoteObjectProxyWithErrorHandler { NSLog("helper: \($0)") } as? PorpoiseHelperProtocol
        for p in paths { proxy?.takeOwnership(ofTrashed: p) { if let e = $0 { NSLog("take ownership of \(p): \(e)") } } }
    }

    enum Outcome {
        case done
        /// A command ran and failed (its message).
        case failed(String)
        /// The helper couldn't be reached before anything ran: the caller can install it or ask for a password.
        case unavailable(String)
    }

    /// Runs file tools as administrator (see PorpoiseHelperInfo.allowedTools), in order, over one connection: the
    /// helper quits when it closes, so one action is one short run. Stops at the first failure, except for tools in
    /// `bestEffort`. Checks first that the helper answers at all, so a broken one can't freeze the window.
    static func run(_ commands: [[String]], bestEffort: Set<String> = []) -> Outcome {
        // Test instances take commands from other processes (DebugBridge): they never get root.
        guard !Settings.isTesting else { return .unavailable("Test instances don't use Porpoise's helper.") }
        guard ping(timeout: 4) || ping(timeout: 4) else { return .unavailable("Porpoise's helper didn't answer.") }
        guard let c = connection() else { return .unavailable("This copy of Porpoise isn't signed, so its helper can't be used.") }
        defer { c.invalidate() }
        var failure: String?
        let proxy = c.synchronousRemoteObjectProxyWithErrorHandler { failure = $0.localizedDescription } as? PorpoiseHelperProtocol
        for (i, args) in commands.enumerated() {
            var result: String? = "Porpoise's helper didn't answer."
            proxy?.run(args) { result = $0 }
            if let f = failure { return i == 0 ? .unavailable(f) : .failed(f) }
            if let r = result, !bestEffort.contains(args.first ?? "") { return .failed(r) }
        }
        return .done
    }
}

/// macOS's Local Network permission (needed to list file servers in Network). Browsing asks the first time.
final class LocalNetworkAccess {
    static let shared = LocalNetworkAccess()
    private static let key = "localNetworkAllowed"
    private var browser: NWBrowser?

    /// Last known answer (macOS has no API to ask without browsing).
    var isAllowed: Bool { Settings.store.bool(forKey: Self.key) }

    /// Browses for SMB servers: macOS shows its prompt if it hasn't asked yet. `changed` runs on the main queue.
    func request(changed: @escaping (Bool) -> Void) {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: "local."), using: .tcp)
        b.stateUpdateHandler = { state in
            var allowed: Bool?
            switch state {
            case .ready: allowed = true
            case .waiting(let e), .failed(let e):
                if case .dns(let code) = e, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { allowed = false }
            default: break
            }
            guard let allowed else { return }
            DispatchQueue.main.async {
                Settings.store.set(allowed, forKey: Self.key)
                // Answered: stop browsing (it would otherwise run for the rest of the session).
                self.browser?.cancel()
                self.browser = nil
                changed(allowed)
            }
        }
        b.start(queue: .main)
        browser = b
    }
}
