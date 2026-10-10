import Foundation
import Network
import PorpoiseCore
import ServiceManagement

/// Porpoise's helper for items that belong to the system or other users (see PorpoiseHelperProtocol).
/// Set up once in onboarding: macOS asks you to allow it in System Settings › Login Items (Touch ID or password).
enum PrivilegedHelper {
    static var service: SMAppService { .daemon(plistName: PorpoiseHelperInfo.plistName) }

    static var isEnabled: Bool { service.status == .enabled }

    /// Registers the helper; macOS then lists it in Login Items for you to switch on.
    static func enable() {
        do { try service.register() } catch { NSLog("helper register: \(error)") }
        if service.status != .enabled { SMAppService.openSystemSettingsLoginItems() }
    }

    static func disable() { try? service.unregister() }

    /// Runs file tools as administrator (see PorpoiseHelperInfo.allowedTools), in order, over one connection: the
    /// helper quits when it closes, so one action is one short run. Stops at the first failure, except for tools in
    /// `bestEffort`. Returns nil on success, or what went wrong.
    static func run(_ commands: [[String]], bestEffort: Set<String> = []) -> String? {
        // Test instances take commands from other processes (DebugBridge): they never get root.
        guard !Settings.isTesting else { return "Test instances don't use Porpoise's helper." }
        guard let req = CodeSigning.requirement(identifier: PorpoiseHelperInfo.helperIdentifier) else {
            return "This copy of Porpoise isn't signed, so its helper can't be used."
        }
        let c = NSXPCConnection(machServiceName: PorpoiseHelperInfo.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: PorpoiseHelperProtocol.self)
        c.setCodeSigningRequirement(req)
        c.resume()
        defer { c.invalidate() }
        var failure: String?
        let proxy = c.synchronousRemoteObjectProxyWithErrorHandler { failure = $0.localizedDescription } as? PorpoiseHelperProtocol
        for args in commands {
            var result: String? = "Porpoise's helper didn't answer."
            proxy?.run(args) { result = $0 }
            if let f = failure { return f }
            if let r = result, !bestEffort.contains(args.first ?? "") { return r }
        }
        return nil
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
