import Foundation
import Network

/// macOS's Local Network permission (needed to list file servers in Network). Browsing asks the first time.
public final class LocalNetworkAccess {
    public static let shared = LocalNetworkAccess()
    private static let key = "localNetworkAllowed"
    private var browser: NWBrowser?

    /// Last known answer (macOS has no API to ask without browsing).
    public var isAllowed: Bool { Settings.store.bool(forKey: Self.key) }

    /// Browses for SMB servers: macOS shows its prompt if it hasn't asked yet. `changed` runs on the main queue.
    public func request(changed: @escaping (Bool) -> Void) {
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
