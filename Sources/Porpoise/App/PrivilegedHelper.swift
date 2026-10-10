import AppKit
import Network
import PorpoiseCore
import ServiceManagement

/// Porpoise's helper for items that belong to the system or other users (see PorpoiseHelperProtocol).
/// Set up once in onboarding: macOS asks you to allow it in System Settings › Login Items (Touch ID or password).
enum PrivilegedHelper {
    static var service: SMAppService { .daemon(plistName: PorpoiseHelperInfo.plistName) }

    static var isEnabled: Bool { service.status == .enabled }

    /// Registers the helper; macOS then lists it in Login Items for you to switch on. A registration made for an
    /// older helper binary is replaced first: macOS only starts the exact binary it was registered with.
    static func enable() {
        if service.status != .notRegistered, Settings.store.string(forKey: registeredKey) != helperCodeHash {
            try? service.unregister()
        }
        do { try service.register() } catch { NSLog("helper register: \(error)") }
        Settings.store.set(helperCodeHash, forKey: registeredKey)
        if service.status != .enabled { SMAppService.openSystemSettingsLoginItems() }
    }

    /// The helper binary the current registration was made for.
    private static let registeredKey = "helperRegisteredCodeHash"

    static func disable() { try? service.unregister() }

    /// macOS approves the helper of an app without an Apple team ID as that exact binary (its code hash) and refuses to
    /// start any other ("launch constraint violation"). Releases ship the same helper binary (scripts/build-helper.sh),
    /// so updates keep it approved. When the helper itself changed, this checks once that it still starts; if it
    /// doesn't, it's registered again and the setup step to allow it is shown (one Touch ID).
    static func checkAfterUpdate() {
        guard !Settings.isTesting, let hash = helperCodeHash else { return }
        let key = "helperCheckedCodeHash"
        // Checked, and registered for this very binary: nothing to do.
        guard Settings.store.string(forKey: key) != hash || Settings.store.string(forKey: registeredKey) != hash else { return }
        switch service.status {
        case .enabled:
            DispatchQueue.global(qos: .utility).async {
                let ok = ping()
                DispatchQueue.main.async {
                    if ok { Settings.store.set(hash, forKey: key); Settings.store.set(hash, forKey: registeredKey); return }
                    // Refused (registered for another binary): register this one, then it needs allowing again.
                    try? service.unregister()
                    Settings.store.removeObject(forKey: registeredKey)
                    askToAllow(hash: hash, key: key)
                }
            }
        case .requiresApproval:
            askToAllow(hash: hash, key: key)
        default:
            Settings.store.set(hash, forKey: key)   // never switched on: nothing to check
        }
    }

    private static func askToAllow(hash: String, key: String) {
        Settings.store.set(hash, forKey: key)
        enable()   // registers this binary (replacing an older registration) and opens Login Items
        NotificationCenter.default.post(name: SystemIntegration.statusChanged, object: nil)
        if service.status != .enabled { OnboardingWindowController.show(at: .admin) }
    }

    /// The bundled helper's code hash (what macOS's approval is tied to).
    private static var helperCodeHash: String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PorpoiseHelper")
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// The helper starts and answers (it quits again as soon as the connection closes).
    private static func ping() -> Bool {
        guard let req = CodeSigning.requirement(identifier: PorpoiseHelperInfo.helperIdentifier) else { return false }
        let c = NSXPCConnection(machServiceName: PorpoiseHelperInfo.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: PorpoiseHelperProtocol.self)
        c.setCodeSigningRequirement(req)
        c.resume()
        defer { c.invalidate() }
        var ok = false
        (c.synchronousRemoteObjectProxyWithErrorHandler { _ in } as? PorpoiseHelperProtocol)?.version { ok = !$0.isEmpty }
        return ok
    }

    /// Hands items Porpoise moved into the Trash to the user, so emptying it needs no administrator rights (best effort).
    static func takeOwnership(of paths: [String]) {
        guard !paths.isEmpty, isEnabled, !Settings.isTesting,
              let req = CodeSigning.requirement(identifier: PorpoiseHelperInfo.helperIdentifier) else { return }
        let c = NSXPCConnection(machServiceName: PorpoiseHelperInfo.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: PorpoiseHelperProtocol.self)
        c.setCodeSigningRequirement(req)
        c.resume()
        defer { c.invalidate() }
        let proxy = c.synchronousRemoteObjectProxyWithErrorHandler { NSLog("helper: \($0)") } as? PorpoiseHelperProtocol
        for p in paths { proxy?.takeOwnership(ofTrashed: p) { if let e = $0 { NSLog("take ownership of \(p): \(e)") } } }
    }

    /// Makes sure the helper is on, for an action that needs it: if it's off (or macOS stopped accepting it), a sheet
    /// explains, System Settings opens at Login Items, and this returns true as soon as it's switched on (Touch ID).
    /// False: cancelled. nil: the user chose to type a password instead.
    static func ensureOn(window: NSWindow?) -> Bool? {
        if service.status == .enabled {   // on, but refused by macOS: register this binary again
            try? service.unregister()
            Settings.store.removeObject(forKey: registeredKey)
        }
        enable()
        if service.status == .enabled { return true }
        let a = NSAlert()
        a.messageText = "Turn on Porpoise's helper"
        a.informativeText = "Porpoise uses a small helper for items that belong to the system, such as apps in the Trash. "
            + "In the System Settings window that opened, switch Porpoise on under “Allow in the Background” (Touch ID). "
            + "Porpoise continues on its own, and won't ask again."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Use Password Instead")
        a.window.appearance = NSAppearance(named: .darkAqua)
        // Ends the alert as soon as macOS reports the helper on.
        let poll = Timer(timeInterval: 0.5, repeats: true) { t in
            guard service.status == .enabled else { return }
            t.invalidate()
            NSApp.stopModal(withCode: .OK)
        }
        RunLoop.main.add(poll, forMode: .modalPanel)
        let answer = a.runModal()
        poll.invalidate()
        NSApp.activate()
        switch answer {
        case .OK: return true
        case .alertSecondButtonReturn: return nil
        default: return false
        }
    }

    enum Outcome {
        case done
        /// A command ran and failed (its message).
        case failed(String)
        /// The helper couldn't be reached before anything ran: the caller can ask for a password instead.
        case unavailable(String)
    }

    /// Runs file tools as administrator (see PorpoiseHelperInfo.allowedTools), in order, over one connection: the
    /// helper quits when it closes, so one action is one short run. Stops at the first failure, except for tools in
    /// `bestEffort`.
    static func run(_ commands: [[String]], bestEffort: Set<String> = []) -> Outcome {
        // Test instances take commands from other processes (DebugBridge): they never get root.
        guard !Settings.isTesting else { return .unavailable("Test instances don't use Porpoise's helper.") }
        guard let req = CodeSigning.requirement(identifier: PorpoiseHelperInfo.helperIdentifier) else {
            return .unavailable("This copy of Porpoise isn't signed, so its helper can't be used.")
        }
        let c = NSXPCConnection(machServiceName: PorpoiseHelperInfo.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: PorpoiseHelperProtocol.self)
        c.setCodeSigningRequirement(req)
        c.resume()
        defer { c.invalidate() }
        var failure: String?
        let proxy = c.synchronousRemoteObjectProxyWithErrorHandler { failure = $0.localizedDescription } as? PorpoiseHelperProtocol
        for (i, args) in commands.enumerated() {
            var result: String? = "Porpoise's helper didn't answer."
            proxy?.run(args) { result = $0 }
            // Not reached at all (not started, or refused by macOS): nothing has run yet, if this is the first command.
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
